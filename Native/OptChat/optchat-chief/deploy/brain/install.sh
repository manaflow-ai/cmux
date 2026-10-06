#!/usr/bin/env bash
# Installs the always-on Chief brain for the current macOS user
# (brains/DESIGN-cmux-lawrence.md in the OptChat lab). User LaunchAgents only:
# no sudo, no system LaunchDaemon, no pf, no change to the subrouter, to the
# shared acpmux daemon (com.acpmux.daemon) or to ~/.local/bin.
#
# usage: install.sh --optchat-chief PATH --cmux-tui PATH --acpmux PATH [--brain DIR] [--no-start]
#
# Binaries are copied into $BRAIN/bin (pinned). The host agent starts only when
# $BRAIN/cloud/install.json is paired and names a chief: first run
# `optchat-chief cloud pair --install $BRAIN/cloud/install.json --api-base URL`
# and approve its code in the cmux app (Server > Add Server…); `cloud register`
# with a session token is the fallback (see ../README.md "Always-on brain").
set -euo pipefail

BRAIN="${HOME}/.cmux/brains/chief"
CHIEF="" TUI="" ACPMUX="" START=1
while (($#)); do
  case "$1" in
    --optchat-chief) CHIEF="$2"; shift 2 ;;
    --cmux-tui) TUI="$2"; shift 2 ;;
    --acpmux) ACPMUX="$2"; shift 2 ;;
    --brain) BRAIN="$2"; shift 2 ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "install.sh: $*" >&2; exit 2; }
[[ "$(id -u)" != 0 ]] || die "run as the brain's user, never root"
for b in "$CHIEF" "$TUI" "$ACPMUX"; do [[ -x "$b" ]] || die "not an executable: '$b'"; done
command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]] || die "claude is not installed for $USER"
command -v sr >/dev/null || [[ -x "$HOME/bin/sr" ]] || die "sr is not installed for $USER (claude-sr needs it)"

LA="$HOME/Library/LaunchAgents"
P=ai.manaflow.chief-brain
umask 077
mkdir -p "$BRAIN"/{bin,mux,acpmux,daemon,cloud,logs} "$LA"
chmod 700 "$BRAIN" "$BRAIN"/{bin,mux,acpmux,daemon,cloud,logs}

# rm before cp: overwriting a signed Mach-O in place gets it SIGKILLed.
for pair in "optchat-chief:$CHIEF" "cmux-tui:$TUI" "acpmux:$ACPMUX"; do
  name="${pair%%:*}" src="${pair#*:}"
  rm -f "$BRAIN/bin/$name"
  cp "$src" "$BRAIN/bin/$name"
  chmod 755 "$BRAIN/bin/$name"
done

xml_args() { for a in "$@"; do printf '    <string>%s</string>\n' "$a"; done; }
xml_env() { while (($#)); do printf '    <key>%s</key>\n    <string>%s</string>\n' "$1" "$2"; shift 2; done; }
render() { # label log args-xml env-xml
  local out="$LA/$1.plist" tmp
  tmp="$(mktemp)"
  # Values go through ENVIRON: awk -v refuses newlines.
  R_LABEL="$1" R_LOG="$2" R_ARGS="$3" R_ENV="$4" R_HOME="$HOME" R_BRAIN="$BRAIN" awk '
    { gsub(/@LABEL@/, ENVIRON["R_LABEL"]); gsub(/@LOG@/, ENVIRON["R_LOG"])
      gsub(/@HOME@/, ENVIRON["R_HOME"]); gsub(/@BRAIN@/, ENVIRON["R_BRAIN"]) }
    /^@ARGS@$/ { printf "%s\n", ENVIRON["R_ARGS"]; next }
    /^@ENV@$/ { if (ENVIRON["R_ENV"] != "") printf "%s\n", ENVIRON["R_ENV"]; next }
    { print }' "$here/plist.template" > "$tmp"
  plutil -lint "$tmp" >/dev/null
  mv "$tmp" "$out"
  chmod 644 "$out"
  echo "wrote $out"
}

SOCK="$BRAIN/daemon/cmux.sock"
render "$P.daemon" "$BRAIN/logs/daemon.log" \
  "$(xml_args "$BRAIN/bin/cmux-tui" --headless --socket "$SOCK")" ""
# The acpmux agent is the daemon's only supervisor; the host waits for it (OPTCHAT_ACPMUX_SUPERVISED=1).
render "$P.acpmux" "$BRAIN/logs/acpmux.log" \
  "$(xml_args "$BRAIN/bin/acpmux" daemon run)" \
  "$(xml_env ACPMUX_HOME "$BRAIN/acpmux")"
render "$P.host" "$BRAIN/mux/host.log" \
  "$(xml_args "$BRAIN/bin/optchat-chief" host --conversation-source cloud \
      --cloud-install "$BRAIN/cloud/install.json" --daemon-socket "$SOCK" --mux-home "$BRAIN/mux")" \
  "$(xml_env MUX_HOME "$BRAIN/mux" ACPMUX_HOME "$BRAIN/acpmux" ACPMUX_SOCKET "$BRAIN/acpmux/acpmux.sock" \
      ACPMUX_BIN "$BRAIN/bin/acpmux" MUX_HARNESS claude-sr CMUX_DAEMON_SOCKET "$SOCK" \
      OPTCHAT_ACPMUX_SUPERVISED 1)"

((START)) || { echo "not started (--no-start)"; exit 0; }
domain="gui/$(id -u)"
launchctl print "$domain" >/dev/null 2>&1 || domain="user/$(id -u)"
boot() {
  launchctl bootout "$domain/$1" 2>/dev/null || true
  launchctl bootstrap "$domain" "$LA/$1.plist"
  echo "started $1 in $domain"
}
boot "$P.daemon"
boot "$P.acpmux"
if "$BRAIN/bin/optchat-chief" cloud status --install "$BRAIN/cloud/install.json" | grep -q '^token ok'; then
  boot "$P.host"
else
  echo "host NOT started: $BRAIN/cloud/install.json is not paired or names no chief"
  echo "  run: $BRAIN/bin/optchat-chief cloud pair --install $BRAIN/cloud/install.json --api-base URL"
  echo "  then approve the code in the cmux app (Server > Add Server…) and run install.sh again"
fi
