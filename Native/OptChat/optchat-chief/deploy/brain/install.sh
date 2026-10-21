#!/usr/bin/env bash
# Installs the always-on Chief brain for the current macOS user
# (brains/DESIGN-cmux-lawrence.md in the OptChat lab). User LaunchAgents only:
# no sudo, no system LaunchDaemon, no pf, no change to the subrouter, to the
# shared acpmux daemon (com.acpmux.daemon) or to ~/.local/bin.
#
# usage: install.sh --optchat-chief PATH --cmux-tui PATH --cmux PATH --acpmux PATH [--brain DIR] [--harness H] [--claude-base-url URL] [--no-start]
#
# No harness is pinned by default: the host takes acpmux's default (the configured CodeRouter
# route, else the user's own `claude` login), and `engine.json` swaps it per turn.
# --harness H pins MUX_HARNESS=H in the host's LaunchAgent.
#
# --cmux is the Rust `cmux` CLI from the same build (the app's Contents/Resources/bin/cmux).
# It sits next to optchat-chief, so the host pins it first on PATH for the Chief and its
# subagents, and their `cmux` calls reach the brain's daemon (CMUX_TUI_SOCKET).
#
# --claude-base-url URL gives the brain's acpmux its Claude route in its own LaunchAgent
# environment (ANTHROPIC_BASE_URL, and a placeholder ANTHROPIC_AUTH_TOKEN): a route that signs
# in by URL, such as the team subrouter, which ignores the client token. Without it acpmux reads
# the route from a login shell, whose read has a 3 s limit and lost the sign-in on a busy host
# (2026-10-19). A route that needs a real token keeps the `claude /login` sign-in instead.
# Every Claude preset of this brain without its own route (turn, compactor, subagents) then
# uses this URL. Not with --harness claude-sr, which brings its own route.
#
# Binaries are copied into $BRAIN/bin (pinned). The host agent starts only when
# $BRAIN/cloud/install.json is paired and names a chief: first run
# `optchat-chief cloud pair --install $BRAIN/cloud/install.json --api-base URL`
# and approve its code in the cmux app (Server > Add Server…); `cloud register`
# with a session token is the fallback (see ../README.md "Always-on brain").
set -euo pipefail

BRAIN="${HOME}/.cmux/brains/chief"
CHIEF="" TUI="" CLI="" ACPMUX="" HARNESS="" CLAUDE_URL="" START=1
while (($#)); do
  case "$1" in
    --optchat-chief) CHIEF="$2"; shift 2 ;;
    --cmux-tui) TUI="$2"; shift 2 ;;
    --cmux) CLI="$2"; shift 2 ;;
    --acpmux) ACPMUX="$2"; shift 2 ;;
    --brain) BRAIN="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --claude-base-url) CLAUDE_URL="$2"; shift 2 ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "install.sh: $*" >&2; exit 2; }
[[ "$(id -u)" != 0 ]] || die "run as the brain's user, never root"
for b in "$CHIEF" "$TUI" "$CLI" "$ACPMUX"; do [[ -x "$b" ]] || die "not an executable: '$b'"; done
command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]] || die "claude is not installed for $USER"
if [[ -n "$CLAUDE_URL" ]]; then
  url_re='^https?://[^][:space:]&<>"'"'"'[]+$'
  [[ "$CLAUDE_URL" =~ $url_re ]] || die "--claude-base-url must be an http(s) URL without spaces, quotes, brackets or & < > (got '$CLAUDE_URL')"
  [[ "$HARNESS" != claude-sr ]] || die "--claude-base-url and --harness claude-sr both set the Claude route; give one"
fi
if [[ "$HARNESS" == claude-sr ]]; then
  command -v sr >/dev/null || [[ -x "$HOME/bin/sr" ]] || die "sr is not installed for $USER (--harness claude-sr needs it)"
fi

LA="$HOME/Library/LaunchAgents"
P=ai.manaflow.chief-brain
umask 077
mkdir -p "$BRAIN"/{bin,mux,acpmux,daemon,cloud,logs} "$LA"
chmod 700 "$BRAIN" "$BRAIN"/{bin,mux,acpmux,daemon,cloud,logs}

# rm before cp: overwriting a signed Mach-O in place gets it SIGKILLed.
for pair in "optchat-chief:$CHIEF" "cmux-tui:$TUI" "cmux:$CLI" "acpmux:$ACPMUX"; do
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
# The daemon reaches the brain's acpmux (subagent workspaces, remote acpmux attach) through ACPMUX_HOME,
# and the host's tools socket (chief-inspect, the owner's memory inspector) through CMUX_TUI_CHIEF_TOOLS_SOCKET.
render "$P.daemon" "$BRAIN/logs/daemon.log" \
  "$(xml_args "$BRAIN/bin/cmux-tui" --headless --socket "$SOCK")" \
  "$(xml_env ACPMUX_HOME "$BRAIN/acpmux" CMUX_TUI_CHIEF_TOOLS_SOCKET "$BRAIN/mux/optchat/tools.sock")"
# The acpmux agent is the daemon's only supervisor; the host waits for it (OPTCHAT_ACPMUX_SUPERVISED=1).
# acpmux fills the Chief's built-in presets from its own environment (acpmux
# config/chief_builtins.rs): the Chief home for codex homes, and the cmux links a
# subagent pins (the host's pinned env, optchat-chief cmux_env).
acpmux_env=(ACPMUX_HOME "$BRAIN/acpmux" ACPMUX_CHIEF_MUX_HOME "$BRAIN/mux"
  CMUX_TUI_SOCKET "$SOCK" CMUX_MUX_SOCKET "$SOCK" CMUX_CHIEF_OWNER_SOCKET "$SOCK"
  CMUX_BUNDLED_CLI_PATH "$BRAIN/bin/cmux")
if [[ -n "$CLAUDE_URL" ]]; then
  acpmux_env+=(ANTHROPIC_BASE_URL "$CLAUDE_URL" ANTHROPIC_AUTH_TOKEN "unused-route-signs-in-by-url")
  # Said out loud: a copied URL can name a relay or an old router host (2026-10-19).
  echo "acpmux Claude route: $CLAUDE_URL (no login shell read for it)"
else
  echo "acpmux Claude route: none given; acpmux reads it from the login shell (3 s limit)"
fi
render "$P.acpmux" "$BRAIN/logs/acpmux.log" \
  "$(xml_args "$BRAIN/bin/acpmux" daemon run)" \
  "$(xml_env "${acpmux_env[@]}")"
host_env=(MUX_HOME "$BRAIN/mux" ACPMUX_HOME "$BRAIN/acpmux" ACPMUX_SOCKET "$BRAIN/acpmux/acpmux.sock"
  ACPMUX_BIN "$BRAIN/bin/acpmux" CMUX_DAEMON_SOCKET "$SOCK" OPTCHAT_ACPMUX_SUPERVISED 1)
[[ -z "$HARNESS" ]] || host_env+=(MUX_HARNESS "$HARNESS")
render "$P.host" "$BRAIN/mux/host.log" \
  "$(xml_args "$BRAIN/bin/optchat-chief" host --conversation-source cloud \
      --cloud-install "$BRAIN/cloud/install.json" --daemon-socket "$SOCK" --mux-home "$BRAIN/mux")" \
  "$(xml_env "${host_env[@]}")"

((START)) || { echo "not started (--no-start)"; exit 0; }
domain="gui/$(id -u)"
launchctl print "$domain" >/dev/null 2>&1 || domain="user/$(id -u)"
boot() {
  launchctl bootout "$domain/$1" 2>/dev/null || true
  # bootout returns before launchd has unloaded the agent; a bootstrap before
  # that fails with "5: Input/output error". Wait for it (at most 30 s).
  local i
  for i in $(seq 1 60); do
    launchctl print "$domain/$1" >/dev/null 2>&1 || break
    sleep 0.5
  done
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
