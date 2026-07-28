#!/usr/bin/bash
# Creado por: rcv11x (Alejandro M) (2026)
# Licencia: MIT
# EasyWallen - gestor de waywallen para Linux

set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
    echo "HOME no apunta a ninguna carpeta valida, no sigo" >&2
    exit 1
fi

# --- colores ---
default="\033[0m"
bold="\033[1m"
dim="\033[2m"
red="\033[31m"
green="\033[32m"
yellow="\033[33m"
blue="\033[34m"
cyan="\033[36m"
prompt="$(echo -e "${bold}${cyan}➜${default} Elige una opcion: ")"

accent="#38b4ee"

# --- config ---
repo_app="waywallen/waywallen"
repo_display="waywallen/waywallen-display"
repo_owe="waywallen/open-wallpaper-engine"

we_appid=431960                        # appid de Wallpaper Engine en Steam

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/waywallen"
plugin_dir="$data_dir/plugins"
link_dir="$HOME/.local/bin"
desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
state_file="${XDG_STATE_HOME:-$HOME/.local/state}/easywallen.state"
state_file_old="${XDG_STATE_HOME:-$HOME/.local/state}/waywallen-setup.state"

appimage="$data_dir/waywallen.AppImage"
desktop_file="$desktop_dir/waywallen.desktop"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
autostart_file="$autostart_dir/waywallen.desktop"

force=0
interactive=0        # solo el menu espera pulsaciones

# --- utilidades ---
function stop_script() {
    echo -e "\n\n${red}[!] Script interrumpido${default}\n"
    exit 130
}
trap stop_script INT

function ok()   { echo -e "${green}✔${default} $*"; }
function info() { echo -e "${blue}→${default} $*"; }
function warn() { echo -e "${yellow}!${default} $*"; }
function fail() { echo -e "${red}✘${default} $*" >&2; }
function note() { echo -e "  ${dim}$*${default}"; }

# desde el menu se espera una tecla; desde un flag no, que si no
# el script se queda colgado en cuanto alguien lo mete en un cron
function press_any_key() {
    [[ $interactive -eq 1 ]] || return 0
    echo
    read -n 1 -s -r -p "$(echo -e "${dim}Pulsa cualquier tecla para continuar...${default}")"
    echo
}

function box() {
    if command -v gum &>/dev/null; then
        gum style --foreground "$accent" --border double --margin "1 2" \
            --padding "1 2" --align center --width "${2:-60}" "$1"
    else
        echo -e "\n${cyan}══ $1 ══${default}\n"
    fi
}

function ask() {
    if command -v gum &>/dev/null; then
        gum confirm "$1"
    else
        local r
        read -r -p "$(echo -e "${yellow}?${default} $1 [s/N] ")" r
        [[ "$r" =~ ^[sSyY]$ ]]
    fi
}

function pkg_manager_hint() {
    if   command -v pacman &>/dev/null; then echo "sudo pacman -S $*"
    elif command -v dnf    &>/dev/null; then echo "sudo dnf install $*"
    elif command -v apt    &>/dev/null; then echo "sudo apt install $*"
    elif command -v zypper &>/dev/null; then echo "sudo zypper install $*"
    else echo "instala manualmente: $*"
    fi
}

function ensure_gum() {
    command -v gum &>/dev/null && return 0
    [[ "${gum_asked:-0}" == "1" ]] && return 1
    gum_asked=1

    clear
    echo -e "\n${yellow}[!] gum no esta instalado${default}\n"
    echo -e "  gum es lo que pone bonitas las preguntas y los recuadros."
    echo -e "  No es obligatorio: sin el todo funciona igual, mas sencillo.\n"

    local cmd=""
    if   command -v pacman &>/dev/null; then cmd="sudo pacman -S --needed --noconfirm gum"
    elif command -v dnf    &>/dev/null; then cmd="sudo dnf install -y gum"
    fi

    if [[ -z "$cmd" ]]; then
        echo -e "  En tu distro no se instalarlo solo. Si lo quieres:"
        note "https://github.com/charmbracelet/gum#installation"
        press_any_key
        return 1
    fi

    echo -e "  Lo instalo con: ${cyan}$cmd${default}\n"
    read -r -p "$(echo -e "${yellow}?${default} ¿Lo instalo? [S/n] ")" r
    if [[ "$r" =~ ^[nN]$ ]]; then
        note "vale, seguimos sin el"
        sleep 1
        return 1
    fi

    if $cmd; then
        ok "gum instalado"
        sleep 1
        return 0
    fi

    fail "no he podido instalarlo, seguimos sin el"
    note "si lo quieres: https://github.com/charmbracelet/gum#installation"
    press_any_key
    return 1
}

function check_deps() {
    local missing=() c
    for c in curl jq unzip; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if ((${#missing[@]})); then
        fail "faltan dependencias: ${missing[*]}"
        note "$(pkg_manager_hint "${missing[@]}")"
        press_any_key
        return 1
    fi
    return 0
}

function check_fuse() {
    # muchas distros ya solo traen fuse3
    ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
    [[ -e /usr/lib/libfuse.so.2 || -e /usr/lib64/libfuse.so.2 ]] && return 0
    return 1
}

function warn_fuse() {
    check_fuse && return 0
    echo
    warn "te falta libfuse2 y sin eso el AppImage puede no abrirse"
    note "$(pkg_manager_hint fuse2)   ${dim}(en Debian/Ubuntu: libfuse2)${default}"
    note "si no quieres instalarlo: $appimage --appimage-extract-and-run"
}

# devuelve niri, hyprland, sway, cosmic o vacio. Arrancando el
# compositor desde una tty, XDG_CURRENT_DESKTOP suele venir vacio,
# asi que hay que mirar tambien sus variables y sus procesos
function detect_compositor() {
    local d="${XDG_CURRENT_DESKTOP:-}"

    shopt -s nocasematch
    case "$d" in
        *niri*)     shopt -u nocasematch; echo "niri";     return ;;
        *hyprland*) shopt -u nocasematch; echo "hyprland"; return ;;
        *sway*)     shopt -u nocasematch; echo "sway";     return ;;
        *cosmic*)   shopt -u nocasematch; echo "cosmic";   return ;;
    esac
    shopt -u nocasematch

    [[ -n "${NIRI_SOCKET:-}" ]]                && { echo "niri";     return; }
    [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && { echo "hyprland"; return; }
    [[ -n "${SWAYSOCK:-}" ]]                   && { echo "sway";     return; }

    pgrep -x niri        &>/dev/null && { echo "niri";     return; }
    pgrep -x Hyprland    &>/dev/null && { echo "hyprland"; return; }
    pgrep -x sway        &>/dev/null && { echo "sway";     return; }
    pgrep -x cosmic-comp &>/dev/null && { echo "cosmic";   return; }

    echo ""
}

function detect_desktop() {
    local d="${XDG_CURRENT_DESKTOP:-}" out
    shopt -s nocasematch
    case "$d" in
        *kde*|*plasma*)                              out="kde" ;;
        *gnome*)                                     out="gnome" ;;
        *hyprland*|*niri*|*sway*|*cosmic*|*wlroots*) out="layershell" ;;
        *)                                           out="" ;;
    esac
    shopt -u nocasematch

    if [[ -z "$out" ]]; then
        if [[ -n "$(detect_compositor)" ]]; then
            out="layershell"
        elif [[ "${KDE_FULL_SESSION:-}" == "true" ]]; then
            out="kde"
        elif [[ -n "${GNOME_SHELL_SESSION_MODE:-}" ]]; then
            out="gnome"
        else
            out="desconocido"
        fi
    fi

    echo "$out"
}

# --- estado ---
function state_get() {
    [[ -f "$state_file" ]] || return 0
    awk -F= -v k="$1" '$1==k {print $2}' "$state_file"
}

function state_set() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$state_file")"; touch "$state_file"
    tmp="$(mktemp)"
    awk -F= -v k="$key" '$1!=k' "$state_file" > "$tmp"
    echo "$key=$val" >> "$tmp"
    mv "$tmp" "$state_file"
}

function state_del() {
    local tmp
    [[ -f "$state_file" ]] || return 0
    tmp="$(mktemp)"
    awk -F= -v k="$1" '$1!=k' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
}

# antes la extension se guardaba con la clave 'kde' y el script tenia otro nombre
function migrate_state() {
    local old
    if [[ -f "$state_file_old" && ! -f "$state_file" ]]; then
        mkdir -p "$(dirname "$state_file")"
        mv "$state_file_old" "$state_file"
    fi
    old="$(state_get kde)"
    if [[ -n "$old" && -z "$(state_get display)" ]]; then
        state_set display "$old"
        state_del kde
    fi
}

function app_installed() { [[ -x "$appimage" ]]; }

function autostart_on() { [[ -f "$autostart_file" ]]; }

# KDE y GNOME leen ~/.config/autostart; los compositores tipo niri
# o hyprland no, ahi la linea va en su propia configuracion
function enable_autostart() {
    mkdir -p "$autostart_dir"
    cat > "$autostart_file" << EOF
[Desktop Entry]
Type=Application
Name=Waywallen
Comment=Fondos dinamicos
Exec=$appimage
Icon=preferences-desktop-wallpaper
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
}

function disable_autostart() { rm -f "$autostart_file"; }

function in_path() {
    [[ ":$PATH:" == *":$link_dir:"* ]]
}

function detect_shell() {
    local sh
    sh="$(ps -o comm= -p "$PPID" 2>/dev/null | tr -d ' -')"
    [[ -n "$sh" ]] || sh="$(basename "${SHELL:-bash}")"
    echo "$sh"
}

# se ofrece a arreglarlo, que si no el usuario se queda con un
# "command not found" y pensando que la instalacion ha fallado
function path_hint() {
    in_path && return 0

    local sh rc line
    sh="$(detect_shell)"
    warn "$link_dir no esta en tu \$PATH"

    case "$sh" in
        fish)
            if ask "¿Te lo añado al PATH de fish?"; then
                if fish -c "fish_add_path $link_dir" 2>/dev/null; then
                    ok "añadido, abre una terminal nueva para que aplique"
                    return 0
                fi
                fail "no he podido, hazlo tu: fish_add_path $link_dir"
                return 1
            fi
            note "cuando quieras: fish_add_path $link_dir"
            return 0 ;;
        zsh)  rc="$HOME/.zshrc" ;;
        *)    rc="$HOME/.bashrc" ;;
    esac

    line="export PATH=\"\$PATH:$link_dir\""

    if [[ -f "$rc" ]] && grep -qF "$link_dir" "$rc"; then
        note "ya aparece en $(basename "$rc"), abre una terminal nueva"
        return 0
    fi

    if ask "¿Lo añado a $(basename "$rc")?"; then
        printf '\n# waywallen (EasyWallen)\n%s\n' "$line" >> "$rc"
        ok "añadido a $rc, abre una terminal nueva para que aplique"
    else
        note "cuando quieras, añade a $(basename "$rc"): $line"
    fi
}

function display_installed() {
    if command -v kpackagetool6 &>/dev/null; then
        kpackagetool6 --type Plasma/Wallpaper -l 2>/dev/null | grep -qi waywallen && return 0
    fi
    if command -v gnome-extensions &>/dev/null; then
        gnome-extensions list 2>/dev/null | grep -qi waywallen && return 0
    fi
    if [[ "$(detect_desktop)" == "layershell" ]]; then
        app_installed && return 0
    fi
    return 1
}

function running() { pgrep -x waywallen &>/dev/null; }

# el kernel trunca el nombre del proceso a 15 caracteres, por eso se
# busca "waywallen-layer" y no "waywallen-layer-shell", que nunca casaria
function layershell_running() { pgrep -x waywallen-layer &>/dev/null; }

function start_waywallen() {
    [[ -x "$appimage" ]] || { fail "no encuentro waywallen instalado"; return 1; }

    if command -v setsid &>/dev/null; then
        setsid "$appimage" &>/dev/null < /dev/null &
    else
        nohup "$appimage" &>/dev/null < /dev/null &
    fi
    disown &>/dev/null

    local i
    for i in {1..8}; do
        sleep 1
        running && return 0
    done
    return 1
}

# no vale con lanzar el pkill y seguir: si sustituyes el AppImage o
# arrancas otra instancia mientras el viejo aun esta guardando su
# configuracion, se pierden los ajustes del fondo
function stop_waywallen() {
    running || return 0

    pkill -x waywallen-ui    &>/dev/null
    pkill -x waywallen-layer &>/dev/null
    pkill -x waywallen       &>/dev/null

    local i
    for i in {1..10}; do
        running || { sleep 1; return 0; }   # margen para que acabe de escribir
        sleep 1
    done

    warn "waywallen no responde, lo cierro a la fuerza"
    pkill -9 -x waywallen-ui    &>/dev/null
    pkill -9 -x waywallen-layer &>/dev/null
    pkill -9 -x waywallen       &>/dev/null
    sleep 1
}

# copia de los ajustes antes de tocar nada, por si una actualizacion
# se lleva por delante la configuracion de algun fondo
function backup_config() {
    local src="$HOME/.config/waywallen"
    local dst="$data_dir/config-backup"
    [[ -d "$src" ]] || return 0
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -a "$src/." "$dst/" 2>/dev/null && return 0
    return 1
}

function owe_installed() {
    [[ -d "$plugin_dir" ]] || return 1
    find "$plugin_dir" -maxdepth 1 -iname '*wallpaper-engine*' 2>/dev/null | grep -q .
}

function owe_dir() {
    find "$plugin_dir" -maxdepth 1 -iname '*wallpaper-engine*' -type d 2>/dev/null | head -n1
}

# el plugin puesto desde la UI no deja version en el estado
function owe_version() {
    local ver dir f
    ver="$(state_get owe)"
    [[ -n "$ver" ]] && { echo "$ver"; return 0; }

    dir="$(owe_dir)"
    [[ -n "$dir" ]] || return 1

    for f in "$dir"/*.json "$dir"/*.toml "$dir"/*.yaml "$dir"/*.yml \
             "$dir"/metadata* "$dir"/manifest* "$dir"/plugin*; do
        [[ -r "$f" && -f "$f" ]] || continue
        ver="$(grep -oiE '"?version"?[[:space:]]*[:=][[:space:]]*"?v?[0-9]+(\.[0-9]+)+' "$f" \
               | head -n1 | grep -oE '[0-9]+(\.[0-9]+)+')"
        if [[ -n "$ver" ]]; then
            state_set owe "$ver"
            echo "$ver"
            return 0
        fi
    done
    return 1
}

function current_label() {
    local ver; ver="$(state_get "$1")"
    if [[ -n "$ver" ]]; then
        echo "$ver"
    elif "$2"; then
        echo "instalado (version ?)"
    else
        echo "no instalado"
    fi
}

function component_label_display() {
    if [[ "$(detect_desktop)" == "layershell" ]]; then
        if app_installed; then
            echo "${green}incluida"
        else
            echo "${dim}no instalado"
        fi
        return
    fi
    component_label display display_installed
}

function component_label_owe() {
    local ver
    if ver="$(owe_version)" && [[ -n "$ver" ]]; then
        echo "${green}${ver}$(update_suffix owe)"
    elif owe_installed; then
        echo "${green}instalado ${dim}(version ?)"
    else
        echo "${dim}no instalado"
    fi
}

function component_label() {
    local ver; ver="$(state_get "$1")"
    if [[ -n "$ver" ]] && "$2"; then
        echo "${green}${ver}$(update_suffix "$1")"
    elif "$2"; then
        echo "${green}instalado ${dim}(version ?)"
    else
        echo "${dim}no instalado"
    fi
}

# --- actualizaciones ---
# el menu no puede llamar a la API cada vez que se dibuja: son 60
# peticiones por hora y ademas se notaria el tiron. Se cachea 6 horas.
update_cache_ttl=21600

function cache_stale() {
    local last now
    last="$(state_get checked_at)"
    [[ -n "$last" ]] || return 0
    now="$(date +%s)"
    (( now - last > update_cache_ttl ))
}

function refresh_update_cache() {
    local repo json ver
    for repo in app display owe; do
        case "$repo" in
            app)     json="$(api_release "$repo_app" 2>/dev/null)" ;;
            display) json="$(api_release "$repo_display" 2>/dev/null)" ;;
            owe)     json="$(api_release "$repo_owe" 2>/dev/null)" ;;
        esac
        [[ -n "${json:-}" ]] || continue
        ver="$(rel_version "$json")"
        [[ -n "$ver" ]] && state_set "latest_$repo" "$ver"
    done
    state_set checked_at "$(date +%s)"
}

function has_update() {
    local comp="$1" latest actual
    latest="$(state_get "latest_$comp")"
    [[ -n "$latest" ]] || return 1

    case "$comp" in
        app)
            app_installed || return 1
            actual="$(state_get app)" ;;
        display)
            [[ "$(detect_desktop)" =~ ^(kde|gnome)$ ]] || return 1
            display_installed || return 1
            actual="$(state_get display)" ;;
        owe)
            owe_installed || return 1
            actual="$(owe_version)" ;;
    esac

    [[ -n "$actual" ]] || return 1
    [[ "$actual" != "$latest" ]]
}

function update_suffix() {
    has_update "$1" || return 0
    echo " ${yellow}🔄 $(state_get "latest_$1")"
}

function badge() {
    local c
    for c in "$@"; do
        has_update "$c" && { echo " 🔄"; return 0; }
    done
    echo ""
}

# --- github ---
function api_release() {
    local resp code body
    resp="$(curl -sL --retry 2 -w $'\n%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null)"

    if [[ -z "$resp" ]]; then
        fail "sin conexion con GitHub, ¿tienes red?"
        return 1
    fi

    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    case "$code" in
        200) echo "$body"; return 0 ;;
        403|429)
            fail "GitHub no me deja hacer mas consultas por ahora"
            note "son 60 por hora; espera un rato o exporta un GITHUB_TOKEN"
            return 1 ;;
        404)
            fail "$1 no ha publicado ninguna version todavia"
            return 1 ;;
        *)
            fail "GitHub ha respondido con un error ($code)"
            return 1 ;;
    esac
}

function rel_version() { jq -r '.tag_name // empty' <<< "$1" | sed 's/^v//'; }

# prueba los patrones en orden y devuelve la primera descarga que casa
function asset_url() {
    local json="$1"; shift
    local re url
    for re in "$@"; do
        url="$(jq -r --arg re "$re" \
            '[.assets[] | select(.name | test($re))] | .[0].browser_download_url // empty' \
            <<< "$json")"
        [[ -n "$url" ]] && { echo "$url"; return 0; }
    done
    return 1
}

# cuantos ficheros (sin contar directorios) declara el zip
function zip_entries() {
    unzip -Z1 "$1" 2>/dev/null | grep -vc '/$'
}

# el unzip clasico no entiende zstd ni xz dentro de un zip y se salta
# esas entradas sin avisar demasiado, asi que no vale con mirar si ha
# salido "algo": hay que comprobar que ha salido TODO
function zip_extract() {
    local zip="$1" dest="$2" prog want got
    mkdir -p "$dest"
    want="$(zip_entries "$zip")"

    unzip -qo "$zip" -d "$dest" &>/dev/null
    got="$(find "$dest" -type f 2>/dev/null | wc -l)"
    if [[ "$want" -gt 0 && "$got" -ge "$want" ]]; then
        return 0
    fi
    [[ "$got" -gt 0 ]] && note "unzip solo ha sacado $got de $want archivos, pruebo con otra cosa"

    if command -v bsdtar &>/dev/null; then
        rm -rf "${dest:?}"/* 2>/dev/null
        bsdtar -xf "$zip" -C "$dest" &>/dev/null
        got="$(find "$dest" -type f 2>/dev/null | wc -l)"
        if [[ "$got" -ge "$want" ]]; then
            note "descomprimido con bsdtar ($got ficheros)"
            return 0
        fi
    fi

    for prog in 7zz 7z 7za; do
        command -v "$prog" &>/dev/null || continue
        rm -rf "${dest:?}"/* 2>/dev/null
        "$prog" x -y -o"$dest" "$zip" &>/dev/null
        got="$(find "$dest" -type f 2>/dev/null | wc -l)"
        if [[ "$got" -ge "$want" ]]; then
            note "descomprimido con $prog ($got ficheros)"
            return 0
        fi
    done

    rm -rf "${dest:?}"/* 2>/dev/null
    return 1
}

function extractor_hint() {
    fail "no he podido descomprimir el plugin"
    note "ese zip usa una compresion que unzip no entiende"
    note "instala cualquiera de estos dos y vuelve a darle:"
    note "$(pkg_manager_hint libarchive)   ${dim}(aporta bsdtar)${default}"
    note "$(pkg_manager_hint p7zip)"
}

function asset_digest() {
    jq -r --arg n "$1" '[.assets[] | select(.name == $n)] | .[0].digest // empty' <<< "$2"
}

function check_digest() {
    local file="$1" digest="${2:-}" want got
    [[ -z "$digest" || "$digest" == "null" ]] && return 0
    [[ "$digest" == sha256:* ]] || return 0
    command -v sha256sum &>/dev/null || return 0
    want="${digest#sha256:}"
    got="$(sha256sum "$file" | cut -d' ' -f1)"
    if [[ "$want" != "$got" ]]; then
        fail "el archivo no coincide con el original, algo ha llegado mal"
        return 1
    fi
    ok "archivo verificado"
    return 0
}

function asset_size() {
    jq -r --arg n "$1" '[.assets[] | select(.name == $n)] | .[0].size // empty' <<< "$2"
}

# descarga con barra de progreso y comprueba que llego entero
function fetch() {
    local url="$1" dest="$2" want="${3:-}" got

    echo -e "  ${dim}${url##*/}${default}"
    if ! curl -fL --progress-bar -o "$dest" "$url"; then
        fail "no he podido descargarlo"
        return 1
    fi

    got="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [[ "$got" -lt 1024 ]]; then
        fail "lo descargado no vale, son solo $got bytes"
        return 1
    fi
    if [[ -n "$want" && "$want" != "null" && "$got" != "$want" ]]; then
        fail "la descarga se ha quedado a medias: $got de $want bytes"
        note "seguramente se corto la conexion, vuelve a intentarlo"
        return 1
    fi
    return 0
}

# --- instalar ---
function install_appimage() {
    local mode="${1:-sync}" json ver cur url tmp

    json="$(api_release "$repo_app")" || return 1
    ver="$(rel_version "$json")"
    [[ -n "$ver" ]] || { fail "no consigo saber cual es la ultima version"; return 1; }

    cur="$(state_get app)"
    [[ -f "$appimage" ]] || cur=""

    if [[ "$ver" == "$cur" && $force -eq 0 ]]; then
        ok "waywallen al dia ${dim}($ver)${default}"; return 0
    fi
    if [[ "$mode" == "check" ]]; then
        warn "waywallen: $(current_label app app_installed) ${yellow}→${default} $ver disponible"; return 0
    fi

    url="$(asset_url "$json" "(?i)$(uname -m).*\\.AppImage$" "(?i)\\.AppImage$")" \
        || { fail "la version $ver no trae ningun AppImage"; return 1; }

    mkdir -p "$data_dir" "$link_dir" "$desktop_dir"
    tmp="$(mktemp -d)"
    info "Descargando waywallen $ver"
    if ! fetch "$url" "$tmp/w.AppImage" "$(asset_size "${url##*/}" "$json")"; then
        rm -rf "$tmp"; return 1
    fi
    if ! check_digest "$tmp/w.AppImage" "$(asset_digest "${url##*/}" "$json")"; then
        rm -rf "$tmp"; return 1
    fi
    chmod +x "$tmp/w.AppImage"
    mv -f "$tmp/w.AppImage" "$appimage"
    rm -rf "$tmp"
    ln -sf "$appimage" "$link_dir/waywallen"

    cat > "$desktop_file" << EOF
[Desktop Entry]
Type=Application
Name=Waywallen
Comment=Gestor de fondos dinamicos
Exec=$appimage
Icon=preferences-desktop-wallpaper
Categories=Utility;Settings;
Terminal=false
EOF
    update-desktop-database "$desktop_dir" &>/dev/null

    state_set app "$ver"
    ok "waywallen $ver instalado"
    path_hint
    warn_fuse
}

function install_display() {
    local mode="${1:-sync}" de json ver cur url tmp arch
    de="$(detect_desktop)"

    case "$de" in
        desconocido)
            warn "no consigo saber que escritorio usas"
            note "tendras que instalar la integracion a mano desde $repo_display"
            return 0 ;;
        layershell)
            ok "en tu compositor no hace falta integracion aparte"
            note "el AppImage ya trae waywallen-layer-shell y lo arranca el solo"
            return 0 ;;
        kde)
            command -v kpackagetool6 &>/dev/null || {
                warn "no encuentro las herramientas de Plasma 6, me salto esa parte"; return 0; } ;;
    esac

    json="$(api_release "$repo_display")" || return 1
    ver="$(rel_version "$json")"
    cur="$(state_get display)"

    if [[ "$ver" == "$cur" && $force -eq 0 ]]; then
        ok "integracion de $de al dia ${dim}($ver)${default}"; return 0
    fi
    if [[ "$mode" == "check" ]]; then
        warn "integracion $de: $(current_label display display_installed) ${yellow}→${default} $ver disponible"; return 0
    fi

    arch="$(uname -m)"
    case "$de" in
        kde)   url="$(asset_url "$json" "(?i)kde.*${arch}.*embed.*\\.zip$" \
                                        "(?i)kde.*${arch}.*\\.zip$")" ;;
        gnome) url="$(asset_url "$json" "(?i)gnome.*${arch}.*\\.zip$" \
                                        "(?i)gnome.*\\.zip$")" ;;
    esac
    [[ -n "${url:-}" ]] || { fail "no hay descarga de la integracion de $de para $arch"; return 1; }

    tmp="$(mktemp -d)"
    local fname="${url##*/}"
    info "Descargando integracion de $de $ver"
    if ! fetch "$url" "$tmp/$fname" "$(asset_size "$fname" "$json")"; then
        rm -rf "$tmp"; return 1
    fi

    if ! check_digest "$tmp/$fname" "$(asset_digest "$fname" "$json")"; then
        rm -rf "$tmp"; return 1
    fi

    case "$de" in
        kde)
            if kpackagetool6 --type Plasma/Wallpaper -u "$tmp/$fname" &>/dev/null; then
                ok "extension de Plasma actualizada ${dim}($ver)${default}"
            elif kpackagetool6 --type Plasma/Wallpaper -i "$tmp/$fname" &>/dev/null; then
                ok "extension de Plasma instalada ${dim}($ver)${default}"
            else
                rm -rf "$tmp"; fail "Plasma no ha aceptado la extension"; return 1
            fi
            needs_shell_restart=1 ;;
        gnome)
            if gnome-extensions install --force "$tmp/$fname"; then
                ok "extension de GNOME instalada ${dim}($ver)${default}"
                warn "cierra sesion y vuelve a entrar para que GNOME la cargue"
            else
                rm -rf "$tmp"; fail "GNOME no ha aceptado la extension"; return 1
            fi ;;
    esac

    rm -rf "$tmp"
    state_set display "$ver"
}

function install_owe() {
    local mode="${1:-sync}" json ver cur url tmp top target n src backup

    json="$(api_release "$repo_owe")" || return 1
    ver="$(rel_version "$json")"
    if [[ -z "$ver" ]]; then
        warn "el plugin todavia no tiene ninguna version publicada"
        return 0
    fi
    cur="$(owe_version)"

    if [[ "$ver" == "$cur" && $force -eq 0 ]]; then
        ok "open-wallpaper-engine al dia ${dim}($ver)${default}"; return 0
    fi
    if [[ "$mode" == "check" ]]; then
        if [[ -z "$cur" ]] && owe_installed; then
            warn "tienes el plugin instalado pero no se de que version es"
            note "la ultima es $ver, dale a la opcion 3 y se pone al dia"
        else
            warn "open-wallpaper-engine: ${cur:-no instalado} ${yellow}→${default} $ver disponible"
        fi
        return 0
    fi

    url="$(asset_url "$json" \
            "(?i)open-wallpaper-engine.*$(uname -m).*\\.zip$" \
            "(?i)open-wallpaper-engine.*\\.zip$" \
            "(?i)\\.zip$")" || { fail "la version $ver no trae el paquete del plugin"; return 1; }

    local reabrir_owe=0
    if running; then
        warn "waywallen esta abierto y el plugin no se puede cambiar mientras corre"
        if ask "¿Lo cierro y lo vuelvo a abrir al terminar?"; then
            backup_config
            info "cerrando waywallen"
            stop_waywallen
            reabrir_owe=1
        else
            note "si no lo cierras, el plugin no cargara hasta que lo reinicies"
            ask "¿Sigo de todas formas?" || return 0
        fi
    fi

    tmp="$(mktemp -d)"
    info "Descargando open-wallpaper-engine $ver"
    local bytes mb
    bytes="$(asset_size "${url##*/}" "$json")"
    if [[ -n "$bytes" && "$bytes" != "null" ]]; then
        mb=$(( bytes / 1048576 ))
        warn "son $mb MB, esto va para largo"
    fi
    if ! fetch "$url" "$tmp/p.zip" "$(asset_size "${url##*/}" "$json")"; then
        rm -rf "$tmp"; return 1
    fi
    if ! check_digest "$tmp/p.zip" "$(asset_digest "${url##*/}" "$json")"; then
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "$plugin_dir"
    if ! zip_extract "$tmp/p.zip" "$tmp/x"; then
        local keep="/tmp/waywallen-plugin-$$.zip"
        mv "$tmp/p.zip" "$keep"
        rm -rf "$tmp"
        extractor_hint
        note "lo he dejado en $keep, tambien puedes meterlo tu desde Plugins → +"
        return 1
    fi

    # el zip puede traer una carpeta raiz o el contenido suelto
    top="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    n="$(find "$tmp/x" -mindepth 1 -maxdepth 1 | wc -l)"
    if [[ -n "$top" && "$n" -eq 1 ]]; then
        target="$plugin_dir/$(basename "$top")"
        src="$top"
    else
        target="$plugin_dir/org.waywallen.open-wallpaper-engine"
        src="$tmp/x"
    fi

    backup=""
    if [[ -d "$target" ]]; then
        backup="${target}.bak.$$"
        if ! mv "$target" "$backup"; then
            rm -rf "$tmp"; fail "no puedo mover el plugin anterior para hacerle sitio"; return 1
        fi
        note "copia de seguridad en $backup"
    fi

    mkdir -p "$target"
    if cp -a "$src/." "$target/"; then
        [[ -n "$backup" ]] && rm -rf "$backup"
    else
        fail "algo ha fallado copiando, dejo el plugin como estaba"
        rm -rf "$target"
        [[ -n "$backup" ]] && mv "$backup" "$target"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    state_set owe "$ver"
    ok "open-wallpaper-engine $ver instalado"
    note "$target"

    if [[ $reabrir_owe -eq 1 ]]; then
        echo
        info "volviendo a abrir waywallen"
        start_waywallen && ok "waywallen en marcha con el plugin cargado" \
                        || { fail "no ha vuelto a arrancar"; note "abrelo tu: $appimage"; }
    fi
    note "si waywallen no lo detecta, importalo a mano: Plugins → + → el zip"
}

# --- steam ---
function steam_roots() {
    echo "$HOME/.steam/steam"
    echo "$HOME/.steam/root"
    echo "$HOME/.local/share/Steam"
    echo "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    echo "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
}

function steam_libraries() {
    local root vdf
    while read -r root; do
        vdf="$root/steamapps/libraryfolders.vdf"
        [[ -r "$vdf" ]] || continue
        echo "$root"
        sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf"
    done < <(steam_roots) | sort -u
}

# devuelve las tres rutas separadas por | porque bash no sabe
# devolver varias cosas de una funcion
function find_we() {
    local lib inst work
    while read -r lib; do
        [[ -d "$lib/steamapps" ]] || continue
        inst="$lib/steamapps/common/wallpaper_engine"
        work="$lib/steamapps/workshop/content/$we_appid"
        if [[ -d "$inst" || -d "$work" ]]; then
            echo "$lib|$([[ -d "$inst" ]] && echo "$inst")|$([[ -d "$work" ]] && echo "$work")"
            return 0
        fi
    done < <(steam_libraries)
    return 1
}

function detect_steam() {
    clear
    show_banner
    box "🎮 BUSCANDO WALLPAPER ENGINE" 60

    local found lib inst work fs count
    if ! found="$(find_we)"; then
        fail "no encuentro Wallpaper Engine en ninguna de tus librerias de Steam"
        echo
        note "estas son las librerias que veo:"
        steam_libraries | sed 's/^/      /'
        echo
        note "instalalo desde Steam: Ajustes → Compatibilidad → Steam Play para todos los titulos"
        note "no hace falta abrirlo nunca, basta con que los archivos esten ahi"
        press_any_key
        return 1
    fi

    IFS='|' read -r lib inst work <<< "$found"

    ok "Libreria de Steam  ${cyan}$lib${default}"
    if [[ -n "$inst" ]]; then
        ok "Wallpaper Engine   ${cyan}$inst${default}"
    else
        warn "Wallpaper Engine   sin instalar (solo veo fondos del workshop)"
    fi
    if [[ -n "$work" ]]; then
        count="$(find "$work" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
        ok "Workshop           ${cyan}$work${default} ${dim}($count fondos)${default}"
    else
        warn "Workshop           vacio, suscribete a algun fondo desde Steam"
    fi

    fs="$(findmnt -no FSTYPE --target "$lib" 2>/dev/null)"
    case "$fs" in
        ntfs*|exfat*|vfat*)
            warn "ese disco es $fs y algunos fondos pueden fallar por mayusculas o permisos" ;;
        "") ;;
        *)  note "sistema de archivos: $fs" ;;
    esac

    state_set steamlib "$lib"

    box "PEGA ESTA RUTA EN WAYWALLEN" 70
    echo -e "   ${bold}${green}$lib${default}\n"
    note "Wallpapers → Add Library → Wallpaper_engine → esa ruta"
    note "ojo: la carpeta que CONTIENE steamapps, no la carpeta $we_appid"

    if command -v wl-copy &>/dev/null; then
        echo -n "$lib" | wl-copy && echo && ok "copiada al portapapeles"
    elif command -v xclip &>/dev/null; then
        echo -n "$lib" | xclip -selection clipboard && echo && ok "copiada al portapapeles"
    fi

    press_any_key
}

# --- diagnostico ---
function view_status() {
    clear
    show_banner
    box "🩺 DIAGNOSTICO" 60

    echo -e "  ${bold}Sistema${default}"
    echo -e "    Escritorio ....... $(detect_desktop) ${dim}(${XDG_SESSION_TYPE:-?})${default}"
    echo -e "    Kernel ........... $(uname -r)"
    if check_fuse; then
        echo -e "    libfuse2 ......... ${green}presente${default}"
    else
        echo -e "    libfuse2 ......... ${yellow}ausente ${dim}(el AppImage puede no arrancar)${default}"
    fi
    echo

    echo -e "  ${bold}Componentes${default}"
    echo -e "    AppImage ......... $(component_label app     app_installed)${default}"
    app_installed || echo -e "        ${dim}→ opcion 1 para instalarlo${default}"

    echo -e "    Integracion ...... $(component_label_display)${default}"
    if ! display_installed; then
        echo -e "        ${dim}→ opcion 1 para instalarla${default}"
    fi

    echo -e "    Wallpaper Engine . $(component_label_owe)${default}"
    if ! owe_installed; then
        echo -e "        ${dim}→ opcion 3, solo si quieres fondos del Workshop${default}"
    fi

    echo

    echo -e "  ${bold}Estado ahora mismo${default}"
    if running; then
        echo -e "    waywallen ........ ${green}en marcha${default}"
        echo -e "        ${dim}sigue en segundo plano aunque cierres la ventana${default}"
    else
        echo -e "    waywallen ........ ${yellow}parado${default} ${dim}(no hay fondo)${default}"
        echo -e "        ${dim}→ opcion 5 para arrancarlo${default}"
    fi

    if [[ "$(detect_desktop)" =~ ^(kde|gnome)$ ]]; then
        if autostart_on; then
            echo -e "    Al iniciar sesion  ${green}arranca solo${default}"
        else
            echo -e "    Al iniciar sesion  ${yellow}no arranca${default}"
            echo -e "        ${dim}el fondo no se vera hasta que abras waywallen${default}"
        fi
    fi

    if [[ "$(detect_desktop)" == "layershell" ]]; then
        if layershell_running; then
            echo -e "    Cliente l-shell .. ${green}en marcha${default}"
        else
            echo -e "    Cliente l-shell .. ${yellow}parado${default}"
            echo -e "        ${dim}lo arranca waywallen, no lo lances tu${default}"
        fi
    fi
    echo

    echo -e "  ${bold}Configuracion${default}"
    local cfg="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -r "$cfg" ]]; then
        if grep -qi 'wallpaperplugin=.*waywallen' "$cfg"; then
            echo -e "    Fondo de Plasma .. ${green}usando waywallen${default}"
        else
            echo -e "    Fondo de Plasma .. ${red}NO esta puesto a waywallen${default}"
            note "click derecho en el escritorio → Configurar → Tipo de fondo → Waywallen"
        fi
    fi

    local found lib
    if found="$(find_we)"; then
        IFS='|' read -r lib _ _ <<< "$found"
        echo -e "    Steam / WE ....... ${green}$lib${default}"
    else
        echo -e "    Steam / WE ....... ${yellow}no detectado${default}"
        echo -e "        ${dim}→ instala Wallpaper Engine en Steam si quieres fondos del Workshop${default}"
    fi

    next_steps
    press_any_key
}

# lo que le falta al usuario para tener un fondo funcionando
function next_steps() {
    local -a pasos=()
    local de cfg
    de="$(detect_desktop)"
    cfg="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

    if ! app_installed; then
        pasos+=("Instala waywallen con la opcion 1")
    else
        if [[ "$de" == "kde" ]] && ! display_installed; then
            pasos+=("Instala la extension de Plasma con la opcion 1")
        fi
        if ! running; then
            pasos+=("Arranca waywallen con la opcion 5")
        fi
        if [[ "$de" == "kde" && -r "$cfg" ]] && ! grep -qi 'wallpaperplugin=.*waywallen' "$cfg"; then
            pasos+=("Click derecho en el escritorio > Configurar > Tipo de fondo > Waywallen")
        fi
        if [[ "$de" == "layershell" ]] && ! layershell_running && running; then
            pasos+=("El cliente no arranco; reinicia waywallen con la opcion 6")
        fi
        if [[ "$de" =~ ^(kde|gnome)$ ]] && ! autostart_on; then
            pasos+=("Haz que arranque solo al iniciar sesion (opcion 1 te lo ofrece)")
        fi
        if ! owe_installed; then
            pasos+=("Opcional: opcion 3 si quieres fondos del Workshop de Steam")
        fi
    fi

    echo
    if ((${#pasos[@]} == 0)); then
        echo -e "  ${green}${bold}Todo en orden.${default} Si aun no ves el fondo, aplica uno"
        echo -e "  desde la ventana de waywallen y mira su pagina Status."
        return
    fi

    echo -e "  ${bold}Que te falta${default}"
    local i=1 paso
    for paso in "${pasos[@]}"; do
        echo -e "    ${cyan}$i.${default} $paso"
        ((i++))
    done
}

# --- acciones ---
function installation() {
    clear
    show_banner
    check_deps || return 0

    if ! ask "¿Quieres instalar/actualizar waywallen?"; then
        clear; return 0
    fi

    local reabrir=0
    if running; then
        echo
        warn "waywallen esta en marcha"
        note "si lo actualizo mientras esta abierto, el fondo puede caerse"
        if ask "¿Lo cierro ahora y lo vuelvo a abrir al terminar?"; then
            reabrir=1
        else
            note "vale, pero si luego el fondo desaparece, reinicialo con la opcion 6"
        fi
    fi

    clear
    box "⬇️  INSTALANDO WAYWALLEN" 50
    sleep 1

    backup_config
    if [[ $reabrir -eq 1 ]]; then
        info "cerrando waywallen"
        stop_waywallen
    fi

    needs_shell_restart=0
    install_appimage sync
    install_display sync
    if [[ -n "$(state_get owe)" ]] || owe_installed; then
        install_owe sync
    fi

    echo
    if [[ "$needs_shell_restart" == "1" ]]; then
        if ask "Hay que reiniciar plasmashell para cargar la extension. ¿Lo hago?"; then
            systemctl --user restart plasma-plasmashell.service \
                && ok "plasmashell reiniciado" \
                || fail "no he podido reiniciarlo"
        else
            note "hazlo tu: systemctl --user restart plasma-plasmashell.service"
        fi
    fi

    echo
    if [[ $force -eq 0 ]] && app_installed && display_installed; then
        note "si algo se ha quedado a medias, vuelve a lanzarlo con --force para rehacerlo"
    fi

    # Plasma se queda con su plugin de imagen hasta que lo cambias tu
    local cfg="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ "$(detect_desktop)" == "kde" ]] && [[ -r "$cfg" ]] \
       && ! grep -qi 'wallpaperplugin=.*waywallen' "$cfg"; then
        box "⚠️  FALTA UN PASO MANUAL" 66
        echo -e "  Plasma sigue con su fondo de siempre. Para que se vea el tuyo:"
        echo
        echo -e "    ${cyan}1.${default} Click derecho en el escritorio"
        echo -e "    ${cyan}2.${default} Configurar el escritorio y el fondo de pantalla"
        echo -e "    ${cyan}3.${default} Tipo de fondo de pantalla ${yellow}→${default} ${bold}Waywallen${default}"
        echo
        note "esto no lo puedo hacer yo sin meterme en tu configuracion de Plasma"
    fi

    echo
    local launch="waywallen"
    in_path || launch="$appimage"

    local de_now; de_now="$(detect_desktop)"
    if [[ "$de_now" =~ ^(kde|gnome)$ ]] && ! autostart_on; then
        box "QUE ARRANQUE SOLO" 60
        echo -e "  Al encender el ordenador el fondo no se vera hasta que abras"
        echo -e "  waywallen, porque es el quien lo pinta. Se arregla haciendo"
        echo -e "  que arranque con la sesion."
        echo
        if ask "¿Lo dejo puesto en el arranque automatico?"; then
            enable_autostart
            ok "listo, a partir del proximo reinicio el fondo saldra solo"
            note "para quitarlo: rm $autostart_file"
        else
            note "puedes ponerlo tu en Preferencias del sistema → Inicio automatico"
        fi
        echo
    fi

    if [[ "$(detect_desktop)" == "layershell" ]]; then
        box "ARRANCAR AL INICIO" 66
        echo -e "  waywallen tiene que estar abierto para que se vea el fondo, asi"
        echo -e "  que conviene que arranque solo al iniciar sesion:"
        echo
        case "$(detect_compositor)" in
            niri)
                note "en ~/.config/niri/config.kdl:"
                note "    spawn-at-startup \"$launch\""
                note "para probarlo ahora sin reiniciar la sesion:"
                note "    niri msg action spawn -- $launch" ;;
            hyprland)
                note "en ~/.config/hypr/hyprland.conf:"
                note "    exec-once = $launch"
                note "para probarlo ahora sin reiniciar la sesion:"
                note "    hyprctl dispatch exec $launch" ;;
            sway)
                note "en ~/.config/sway/config:"
                note "    exec $launch"
                note "usa exec y no exec_always, o tendras uno nuevo cada recarga"
                note "para probarlo ahora sin reiniciar la sesion:"
                note "    swaymsg exec $launch" ;;
            *)
                note "haz que $launch arranque al iniciar sesion" ;;
        esac
        note "el cliente layer-shell lo abre el solo, no lo lances tu por tu cuenta"
        echo
    fi

    ok "Todo listo."
    echo
    if [[ $reabrir -eq 1 ]]; then
        info "volviendo a abrir waywallen"
        if start_waywallen; then
            ok "waywallen en marcha"
        else
            fail "no ha vuelto a arrancar"
            note "pruebalo a mano: $appimage"
        fi
    elif ! running && ask "¿Abro waywallen ahora?"; then
        start_waywallen && ok "waywallen en marcha" \
                        || { fail "no ha arrancado"; note "pruebalo a mano: $appimage"; }
    elif ! running; then
        note "cuando quieras, lanzalo con: $launch"
    fi

    [[ -d "$data_dir/config-backup" ]] && \
        note "por si acaso, tus ajustes de antes estan copiados en $data_dir/config-backup"

    in_path || path_hint
    press_any_key
}

function check_updates() {
    clear
    show_banner
    check_deps || return 0
    box "🔄 BUSCANDO ACTUALIZACIONES" 50

    state_del checked_at
    refresh_update_cache

    install_appimage check
    install_display check
    { [[ -n "$(state_get owe)" ]] || owe_installed; } && install_owe check

    press_any_key
}

function install_we_support() {
    clear
    show_banner
    check_deps || return 0
    box "🖼️  SOPORTE DE WALLPAPER ENGINE" 60

    echo -e "  Instala el plugin ${cyan}open-wallpaper-engine${default}, que es el que sabe"
    echo -e "  leer los fondos del Workshop de Steam (los ${bold}scene${default} y los ${bold}web${default})."
    echo
    warn "necesitas Wallpaper Engine comprado Y ADEMAS instalado en Steam"
    note "no hace falta abrirlo nunca, basta con que los archivos esten ahi"
    echo

    ask "¿Continuo?" || { clear; return 0; }

    echo
    install_owe sync
    echo
    detect_steam
}

function open_app() {
    clear
    show_banner
    box "🚀 ABRIR WAYWALLEN" 54

    if ! app_installed; then
        fail "aun no tienes waywallen instalado, empieza por la opcion 1"
        press_any_key; return 0
    fi

    if running; then
        warn "ya hay una instancia de waywallen funcionando"
        note "se quedo en segundo plano la ultima vez que lo abriste"
        note "por eso el fondo se sigue viendo aunque no tengas la ventana"
        echo
        echo -e "  Si lo que quieres es ${bold}ver la ventana${default}, abrela desde el menu"
        echo -e "  de aplicaciones. Si algo va mal, mejor la ${bold}opcion 6${default} para reiniciarlo."
        echo
        if ! ask "¿Abro la ventana de todas formas?"; then
            press_any_key; return 0
        fi
    fi

    info "abriendo waywallen"
    if start_waywallen; then
        ok "waywallen funcionando"
        note "seguira en segundo plano aunque cierres la ventana"
        layershell_running && ok "cliente layer-shell funcionando"
    else
        fail "no ha arrancado"
        note "lanzalo desde la terminal para ver el error: $appimage"
    fi
    press_any_key
}

function restart_waywallen() {
    clear
    show_banner
    box "🔁 REINICIAR WAYWALLEN" 54

    echo -e "  Los plugins solo se cargan al abrir waywallen, asi que despues"
    echo -e "  de instalar uno hay que reiniciarlo. Tambien viene bien si el"
    echo -e "  fondo ha dejado de verse."
    echo

    if ! app_installed; then
        fail "waywallen no esta instalado"
        press_any_key; return 0
    fi

    if running; then
        info "cerrando waywallen"
        stop_waywallen
    fi

    info "arrancando"
    if start_waywallen; then
        ok "waywallen en marcha"
        layershell_running && ok "cliente layer-shell en marcha"
    else
        fail "no ha arrancado"
        note "lanzalo a mano para ver el error: $appimage"
    fi
    press_any_key
}

function restart_shell() {
    clear
    show_banner
    box "🔁 REINICIANDO PLASMASHELL" 50
    if systemctl --user restart plasma-plasmashell.service; then
        ok "plasmashell reiniciado"
    else
        fail "no he podido reiniciarlo, ¿seguro que estas en Plasma?"
    fi
    press_any_key
}

function uninstall() {
    clear
    show_banner
    box "🗑️  DESINSTALAR" 50

    if ! ask "¿Seguro que quieres desinstalar waywallen?"; then
        clear; return 0
    fi

    if command -v kpackagetool6 &>/dev/null; then
        local id
        id="$(kpackagetool6 --type Plasma/Wallpaper -l 2>/dev/null \
              | grep -io '[a-z0-9._-]*waywallen[a-z0-9._-]*' | head -n1)"
        if [[ -n "$id" ]]; then
            kpackagetool6 --type Plasma/Wallpaper -r "$id" &>/dev/null \
                && ok "extension de Plasma eliminada ${dim}($id)${default}"
        fi
    fi

    rm -f "$appimage" "$link_dir/waywallen" "$desktop_file"
    disable_autostart
    state_del app; state_del display
    ok "AppImage y lanzador eliminados"

    if ask "¿Borro tambien los plugins descargados?"; then
        rm -rf "$plugin_dir"; state_del owe
        ok "plugins eliminados"
    fi
    rmdir "$data_dir" &>/dev/null

    rm -f "$state_file" "$state_file_old"
    ok "borrado tambien lo que guardaba EasyWallen ${dim}($state_file)${default}"

    echo
    note "tus ajustes y tus fondos siguen donde estaban, en ~/.config/waywallen"
    note "si tambien quieres eso fuera: rm -rf ~/.config/waywallen"
    press_any_key
}

# --- menu ---
function show_banner() {
    local v_app v_dis v_owe de
    v_app="$(component_label app     app_installed)"
    v_dis="$(component_label_display)"
    v_owe="$(component_label_owe)"
    de="$(detect_desktop)"

    echo -e "${cyan} _____              __        __    _ _            ${default}"
    echo -e "${cyan}| ____|__ _ ___ _   \\ \\      / /_ _| | | ___ _ __  ${default}"
    echo -e "${cyan}|  _| / _\` / __| | | \\ \\ /\\ / / _\` | | |/ _ \\ '_ \\ ${default}"
    echo -e "${cyan}| |__| (_| \\__ \\ |_| |\\ V  V / (_| | | |  __/ | | |${default}"
    echo -e "${cyan}|_____\\__,_|___/\\__, | \\_/\\_/ \\__,_|_|_|\\___|_| |_|${default}"
    echo -e "${cyan}                |___/                              ${default}"
    echo
    echo -e "Hola $(whoami)! 👋🏼 | Escritorio: ${yellow}${de}${default}"
    echo -e "waywallen: ${v_app}${default}  ·  integracion: ${v_dis}${default}  ·  plugin Wallpaper Engine: ${v_owe}${default}"
    if app_installed; then
        if running; then
            echo -e "Estado: ${green}● en marcha${default} ${dim}(en segundo plano)${default}"
        else
            echo -e "Estado: ${yellow}○ parado${default} ${dim}(opcion 5 para arrancarlo)${default}"
        fi
    fi
    echo -e "Estas en: 📁 ${yellow}${SCRIPT_DIR}${default}\n"
}

function menu() {
    echo -e "[1] ${cyan}Instalar / Actualizar waywallen *${default}$(badge app display)"
    echo -e "[2] ${cyan}Buscar actualizaciones${default}"
    echo -e "[3] ${cyan}Instalar soporte de Wallpaper Engine${default}$(badge owe)"
    echo -e "[4] ${cyan}Detectar libreria de Steam${default}"
    echo -e "[5] ${cyan}Abrir waywallen${default}"
    echo -e "[6] ${cyan}Reiniciar waywallen${default} ${dim}(tras instalar un plugin)${default}"
    [[ "$(detect_desktop)" == "kde" ]] && echo -e "[7] ${cyan}Reiniciar plasmashell${default}"
    echo -e "[d] ${cyan}Desinstalar${default}"
    echo -e "[i] ${cyan}Diagnostico del sistema${default}"
    echo -e "[0] ${cyan}Exit${default}\n"
}

function show_help() {
    echo -e "\n${bold}EasyWallen${default} - gestor de waywallen\n"
    echo -e "  ${cyan}./easywallen.sh${default}              menu interactivo"
    echo -e "  ${cyan}./easywallen.sh --sync${default}       instala/actualiza sin menu"
    echo -e "  ${cyan}./easywallen.sh --check${default}      mira si hay versiones nuevas"
    echo -e "  ${cyan}./easywallen.sh --plugin${default}     instala open-wallpaper-engine"
    echo -e "  ${cyan}./easywallen.sh --steam${default}      busca la libreria de Steam"
    echo -e "  ${cyan}./easywallen.sh --open${default}       arranca waywallen"
    echo -e "  ${cyan}./easywallen.sh --restart${default}    lo reinicia (tras instalar un plugin)"
    echo -e "  ${cyan}./easywallen.sh --status${default}     diagnostico"
    echo -e "  ${cyan}./easywallen.sh --remove${default}     desinstala"
    echo -e "\n  Extra: ${yellow}--force${default} rehace la instalacion aunque este al dia\n"
}

function main() {
    interactive=1
    clear
    if [[ $(id -u) = 0 || $(whoami) = "root" ]]; then
        echo -e "\n${red}⚠️ Ejecuta el script sin permisos de sudo\n${default}"
        exit 1
    fi

    migrate_state
    ensure_gum

    if app_installed && cache_stale && command -v curl &>/dev/null; then
        echo -e "${dim}Comprobando actualizaciones...${default}"
        refresh_update_cache
    fi

    while true; do
        clear
        show_banner
        menu
        read -r -p "${prompt}" opcion
        case $opcion in
            1) installation ;;
            2) check_updates ;;
            3) install_we_support ;;
            4) detect_steam ;;
            5) open_app ;;
            6) restart_waywallen ;;
            7)
                if [[ "$(detect_desktop)" == "kde" ]]; then
                    restart_shell
                else
                    echo -e "\n${red}[!] Opcion no valida${default}"
                    press_any_key
                fi ;;
            d|D) uninstall ;;
            i) view_status ;;
            0) clear; exit 0 ;;
            *)
                echo -e "\n${red}[!] Opcion no valida${default}"
                press_any_key ;;
        esac
        clear
    done
}

# --- arranque ---
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && force=1
done

migrate_state

case "${1:-}" in
    -h|--help)   show_help ;;
    -s|--sync)   check_deps && { needs_shell_restart=0; install_appimage sync
                                 install_display sync
                                 { [[ -n "$(state_get owe)" ]] || owe_installed; } && install_owe sync; } ;;
    -c|--check)  check_deps && { install_appimage check; install_display check
                                 { [[ -n "$(state_get owe)" ]] || owe_installed; } && install_owe check; } ;;
    -p|--plugin) check_deps && install_owe sync ;;
    --steam)     detect_steam ;;
    --open)      running && ok "ya estaba en marcha" || \
                 { start_waywallen && ok "waywallen en marcha" || fail "no ha arrancado"; } ;;
    --restart)   stop_waywallen
                 start_waywallen && ok "waywallen reiniciado" || fail "no ha arrancado" ;;
    --status)    view_status ;;
    --remove)    uninstall ;;
    --force|"")  main ;;
    *)
        echo -e "${red}❌ Parametro no valido: $1${default}"
        echo -e "Usa --help para ver los parametros disponibles."
        exit 1 ;;
esac
