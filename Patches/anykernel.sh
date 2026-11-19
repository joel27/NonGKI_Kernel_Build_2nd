### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Tech Kernel for Mi11 Ultra (Star) by Tech Master
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=star
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;
[ -n "$AKHOME" ] || AKHOME="${home:-$PWD}"; # AK3 antiguo usa $home

# ===== BEGIN ak_scan =====
# Analiza la imagen del kernel que se va a INSTALAR (la del zip, no la que ya hay en el
# dispositivo) y rellena:
#   AK_METHOD  = config | cadenas | ninguno
#   AK_KSU / AK_SUSFS / AK_NOMOUNT = 1 | 0
#   AK_RELEASE = versión del kernel (banner "Linux version")
#   AK_SUSFS_N = nº de opciones CONFIG_KSU_SUSFS_* activas (solo con método "config")
# Método "config": lee la .config que el propio kernel lleva embebida (CONFIG_IKCONFIG).
# Método "cadenas": si la imagen no trae su config (o el grep del recovery no soporta -b),
#                   busca cadenas características dentro del binario.
# Uso: ak_scan_kernel <imagen> [auto|config|cadenas]
ak_scan_kernel() {
  _img="$1"; _mode="${2:-auto}";
  AK_METHOD=ninguno; AK_KSU=0; AK_SUSFS=0; AK_NOMOUNT=0; AK_RELEASE=""; AK_SUSFS_N=0;
  [ -f "$_img" ] || return 1;
  _tmp="${TMPDIR:-/tmp}/ak_scan.$$"; mkdir -p "$_tmp" 2>/dev/null || _tmp=/tmp;
  _raw="$_img";
  # Image.gz / Image.gz-dtb: se descomprime para poder buscar dentro
  if [ "$(head -c 2 "$_img" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
    zcat "$_img" > "$_tmp/raw" 2>/dev/null || gzip -dc "$_img" > "$_tmp/raw" 2>/dev/null;
    [ -s "$_tmp/raw" ] && _raw="$_tmp/raw";
  fi;
  AK_RELEASE=$(LC_ALL=C grep -a -m1 -o 'Linux version [^ ]*' "$_raw" 2>/dev/null | head -n1 | sed 's/^Linux version //');
  if [ "$_mode" != "cadenas" ]; then
    _off=$(LC_ALL=C grep -abo 'IKCFG_ST' "$_raw" 2>/dev/null | head -n1 | cut -d: -f1);
    case "$_off" in ''|*[!0-9]*) _off="" ;; esac;
    if [ -n "$_off" ]; then
      tail -c +$((_off + 9)) "$_raw" 2>/dev/null | zcat > "$_tmp/config" 2>/dev/null;
      if grep -q '^CONFIG_' "$_tmp/config" 2>/dev/null; then
        AK_METHOD=config;
        if grep -q '^CONFIG_KSU=[ym]' "$_tmp/config"; then AK_KSU=1; fi;
        if grep -q '^CONFIG_KSU_SUSFS=y' "$_tmp/config"; then AK_SUSFS=1; fi;
        if grep -q '^CONFIG_NOMOUNT=[ym]' "$_tmp/config"; then AK_NOMOUNT=1; fi;
        AK_SUSFS_N=$(grep -c '^CONFIG_KSU_SUSFS_[A-Z_]*=y' "$_tmp/config");
      fi;
    fi;
  fi;
  if [ "$AK_METHOD" = "ninguno" ] && [ "$_mode" != "config" ]; then
    AK_METHOD=cadenas;
    if LC_ALL=C grep -qaiE '/data/adb/ksud|kernelsu|bakasu|sukisu' "$_raw" 2>/dev/null; then AK_KSU=1; fi;
    if LC_ALL=C grep -qai 'susfs' "$_raw" 2>/dev/null; then AK_SUSFS=1; fi;
    if LC_ALL=C grep -qai 'nomount' "$_raw" 2>/dev/null; then AK_NOMOUNT=1; fi;
  fi;
  rm -rf "$_tmp" 2>/dev/null;
  return 0;
}
# ===== END ak_scan =====

# Valor de kernel-info.txt (lo genera la compilación). Solo se usa si el hash de la imagen coincide.
ak_info() { sed -n "s/^$1=//p" "$AKHOME/kernel-info.txt" 2>/dev/null | head -n1; }

# Busca la imagen que trae el zip
ak_find_kernel() {
  for _f in Image Image.gz Image.gz-dtb Image-dtb Image.lz4 zImage; do
    if [ -f "$AKHOME/$_f" ]; then echo "$AKHOME/$_f"; return 0; fi;
  done;
  return 1;
}

ak_show_features() {
  _k=$(ak_find_kernel) || { ui_print "- [!] No se encontró la imagen del kernel en el zip"; return 1; };
  ui_print "- [*] Analizando la imagen del kernel a instalar...";
  ak_scan_kernel "$_k";
  if [ "$AK_METHOD" = "ninguno" ]; then
    ui_print "- [!] No se pudo analizar la imagen";
    return 1;
  fi;
  ui_print "- [i] Kernel: ${AK_RELEASE:-desconocido}";
  if [ "$AK_METHOD" = "config" ]; then
    ui_print "- [i] Detección: configuración embebida en la imagen";
  else
    ui_print "- [i] Detección: búsqueda de cadenas (la imagen no trae su config)";
  fi;

  # Nombres y versiones: solo si el manifiesto pertenece exactamente a esta imagen
  _want=$(ak_info image_sha256); _have="";
  if [ -n "$_want" ]; then _have=$(sha256sum "$_k" 2>/dev/null | cut -d' ' -f1); fi;
  _verified=0; if [ -n "$_want" ] && [ "$_want" = "$_have" ]; then _verified=1; fi;

  if [ "$AK_KSU" = 1 ]; then
    _n=""; [ "$_verified" = 1 ] && _n=$(ak_info ksu_name);
    ui_print "- [+] KernelSU detectado${_n:+ ($_n)}";
  else
    ui_print "- [-] KernelSU no detectado";
  fi;
  if [ "$AK_SUSFS" = 1 ]; then
    _n=""; [ "$_verified" = 1 ] && _n=$(ak_info susfs_version);
    _o=""; [ "$AK_SUSFS_N" -gt 0 ] 2>/dev/null && _o="$AK_SUSFS_N opciones";
    _d="$_n"; [ -n "$_o" ] && _d="${_d:+$_d, }$_o";
    ui_print "- [+] SUSFS detectado${_d:+ ($_d)}";
  else
    ui_print "- [-] SUSFS no detectado";
  fi;
  if [ "$AK_NOMOUNT" = 1 ]; then
    _n=""; [ "$_verified" = 1 ] && _n=$(ak_info nomount_version);
    ui_print "- [+] NoMount detectado${_n:+ ($_n)}";
  else
    ui_print "- [-] NoMount no detectado";
  fi;
  if [ -n "$_want" ] && [ "$_verified" = 0 ]; then
    ui_print "- [!] kernel-info.txt no corresponde a esta imagen: se omiten nombres y versiones";
  fi;
}

ui_print " " "- [+] Starting kernel image flashing...";

# boot install
ui_print "- [*] Unpacking boot image...";
dump_boot; # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

ak_show_features;

ui_print "- [+] Flashing kernel image...";
write_boot; # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
## end boot install
