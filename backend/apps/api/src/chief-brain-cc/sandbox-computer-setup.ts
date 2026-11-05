/**
 * The desktop of the Chief's computer (sandbox-computer.ts), as shell: the root install (SETUP) and the per-verb
 * prelude (DESKTOP_PRELUDE). Pure strings with no imports, so backend/chief-cc/bake-computer.sh can print SETUP with
 * bun and bake the same desktop into a snapshot (CHIEF_CC_COMPUTER_SNAPSHOT), where SETUP then installs nothing.
 *
 * The desktop matches the Cloud machines' devbox (web/services/vms/images/devbox/desktop/start-vnc.sh): TigerVNC's
 * Xvnc on display :1 with RFB on 5901 bound to loopback only (no listener the network reaches; the sandbox firewall
 * is unchanged), one D-Bus session bus, the accessibility bus cua-driver reads windows through, and openbox. It runs as
 * the unprivileged `chief` user. cua-driver is the devbox's pinned build (Dockerfile: CUA_DRIVER_RS_VERSION), and
 * xdotool stays for what cua-driver lacks or when it did not install.
 */
export const SCREEN = { width: 1280, height: 800 }
export const DISPLAY = ":1"
export const CUA_DRIVER_RS_VERSION = "0.23.2"
/** The session other shells attach to (DISPLAY, the session bus, the accessibility bus), written by chief-desktop. */
export const DESKTOP_ENV = "/home/chief/.chief-desktop.env"

/** Starts the Chief's desktop when it is not running (after a boot, a stop or a fork); idempotent. Runs as chief. */
const CHIEF_DESKTOP = `#!/bin/bash
export DISPLAY=${DISPLAY}
state=/home/chief/.chief-desktop; mkdir -p "$state"
# fresh: something was (re)started, so the published session is written again (every verb runs this; most find all up).
fresh=""; [ -f ${DESKTOP_ENV} ] || fresh=1
if ! xdpyinfo >/dev/null 2>&1; then
  fresh=1
  if command -v Xvnc >/dev/null 2>&1; then
    # RFB on loopback only (-localhost), as the devbox: nothing outside the VM reaches the screen.
    setsid nohup Xvnc ${DISPLAY} -geometry ${SCREEN.width}x${SCREEN.height} -depth 24 -rfbport 5901 -localhost -SecurityTypes None -AlwaysShared >"$state/xvnc.log" 2>&1 < /dev/null &
  else
    setsid nohup Xvfb ${DISPLAY} -screen 0 ${SCREEN.width}x${SCREEN.height}x24 -nolisten tcp >"$state/xvfb.log" 2>&1 < /dev/null &
  fi
  for _ in $(seq 200); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.05; done
fi
[ -f "$state/session.env" ] && . "$state/session.env"
if command -v dbus-launch >/dev/null 2>&1 && { [ -z "\${DBUS_SESSION_BUS_PID:-}" ] || ! kill -0 "$DBUS_SESSION_BUS_PID" 2>/dev/null; }; then
  fresh=1
  unset DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
  eval "$(dbus-launch --sh-syntax 2>/dev/null)"
  [ -n "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && printf "DBUS_SESSION_BUS_ADDRESS='%s'\\nDBUS_SESSION_BUS_PID=%s\\n" "$DBUS_SESSION_BUS_ADDRESS" "$DBUS_SESSION_BUS_PID" > "$state/session.env"
fi
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-}"
if ! pgrep -u "$(id -u)" -f at-spi-bus-launcher >/dev/null; then
  for l in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do [ -x "$l" ] && { setsid nohup "$l" --launch-immediately >"$state/at-spi.log" 2>&1 < /dev/null & break; }; done
fi
if command -v openbox >/dev/null 2>&1; then pgrep -u "$(id -u)" -x openbox >/dev/null || setsid nohup openbox >"$state/wm.log" 2>&1 < /dev/null &
else pgrep -u "$(id -u)" -x fluxbox >/dev/null || setsid nohup fluxbox >"$state/wm.log" 2>&1 < /dev/null &
fi
xsetroot -solid '#1d1f24' 2>/dev/null || true
a11y=""
if [ -n "$fresh" ] && [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && command -v gdbus >/dev/null 2>&1; then
  gdbus wait --session --timeout 5 org.a11y.Bus >/dev/null 2>&1 || true
  a11y=$(dbus-send --session --print-reply=literal --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null | tr -d ' \\n')
fi
[ -n "$fresh" ] && {
  echo "export DISPLAY='${DISPLAY}'"
  [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && echo "export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'"
  [ -n "$a11y" ] && echo "export AT_SPI_BUS_ADDRESS='$a11y'" && echo "export AT_SPI_BUS='$a11y'"
} > ${DESKTOP_ENV}.tmp && mv -f ${DESKTOP_ENV}.tmp ${DESKTOP_ENV}
[ -f ${DESKTOP_ENV} ] && . ${DESKTOP_ENV}
# cua-driver's daemon on this desktop (it reads windows over the accessibility bus above); bounded wait for it.
if command -v cua-driver >/dev/null 2>&1 && ! cua-driver status >/dev/null 2>&1; then
  setsid -f cua-driver serve >"$state/cua-driver.log" 2>&1 < /dev/null
  for _ in $(seq 40); do cua-driver status >/dev/null 2>&1 && break; sleep 0.25; done
fi
exit 0
`

/** Installs the desktop, cua-driver and the helpers (root). What is already there (a baked snapshot) is skipped. */
export const SETUP = `set -e
export DEBIAN_FRONTEND=noninteractive
id chief >/dev/null 2>&1 || useradd -m -s /bin/bash chief
need=""
for c in Xvnc xdotool openbox import xdpyinfo xsetroot dbus-launch gdbus curl; do command -v "$c" >/dev/null 2>&1 || need=1; done
if [ -n "$need" ]; then
  # A fresh VM's unattended upgrades can hold the dpkg lock for a few minutes: wait for it, don't fail.
  apt-get -o DPkg::Lock::Timeout=120 update -qq
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends tigervnc-standalone-server dbus-x11 at-spi2-core libglib2.0-bin openbox xdotool imagemagick x11-utils x11-xserver-utils fonts-dejavu-core fonts-liberation fonts-noto-color-emoji curl wget ca-certificates >/dev/null
fi
if ! command -v google-chrome >/dev/null 2>&1; then
  wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq /tmp/chrome.deb >/dev/null
  rm -f /tmp/chrome.deb
fi
# cua-driver, pinned as on the devbox (web/services/vms/images/devbox/Dockerfile). Optional: without it every verb
# goes through xdotool.
if ! cua-driver --version 2>/dev/null | grep -q '${CUA_DRIVER_RS_VERSION}'; then
  if curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh; then
    CUA_DRIVER_RS_HOME=/opt/cua-driver CUA_DRIVER_RS_VERSION=${CUA_DRIVER_RS_VERSION} CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh >/tmp/cua-install.log 2>&1 \\
      && chmod -R a+rX /opt/cua-driver || echo "cua-driver did not install (tail /tmp/cua-install.log)" >&2
    rm -f /tmp/cua-install.sh
  else
    echo "cua-driver installer not reached" >&2
  fi
fi
cat > /usr/local/bin/chief-desktop <<'CHIEF_DESKTOP_EOF'
${CHIEF_DESKTOP}CHIEF_DESKTOP_EOF
chmod 755 /usr/local/bin/chief-desktop
su - chief -c /usr/local/bin/chief-desktop
su - chief -c 'DISPLAY=${DISPLAY} xdpyinfo' >/dev/null
if command -v cua-driver >/dev/null 2>&1; then echo "driver cua-driver"; else echo "driver xdotool"; fi
echo ready`

/**
 * The start of every verb's shell (as chief): the desktop up, its session in the environment, and `cua TOOL JSON`,
 * one cua-driver tool on the whole desktop that fails (so the xdotool fallback runs) when cua-driver is missing or
 * answers an error (it can exit 0 with one).
 */
export const DESKTOP_PRELUDE = `export DISPLAY=${DISPLAY}; /usr/local/bin/chief-desktop >/dev/null 2>&1; [ -f ${DESKTOP_ENV} ] && . ${DESKTOP_ENV};
cua() { command -v cua-driver >/dev/null 2>&1 || return 1; out=$(cua-driver call "$1" "$2" 2>&1) || return 1; printf '%s' "$out" | grep -Eq '"isError"[[:space:]]*:[[:space:]]*true|^[[:space:]]*\\{[[:space:]]*"error"' && return 1; printf '%s\\n' "$out"; };`
