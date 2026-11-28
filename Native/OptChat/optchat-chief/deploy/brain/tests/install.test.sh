#!/usr/bin/env bash
# install.sh writes the brain's three LaunchAgents with the environment each process needs.
# The brain's cmux-tui daemon finds the brain's acpmux only through ACPMUX_HOME (G2, remote
# acpmux attach), the same value the acpmux agent gets. --no-start: nothing is loaded.
# No harness is pinned (2026-10-08: agent traffic left the subrouter): the host takes acpmux's
# default harness, `sr` is not needed, and --harness pins one only when given.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/bin" "$tmp/bin"
for b in optchat-chief cmux-tui cmux acpmux claude; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$b"; chmod 755 "$tmp/bin/$b"; done
PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" "$here/install.sh" --optchat-chief "$tmp/bin/optchat-chief" --cmux-tui "$tmp/bin/cmux-tui" \
  --cmux "$tmp/bin/cmux" --acpmux "$tmp/bin/acpmux" --no-start > "$tmp/out.log" 2>&1 || { cat "$tmp/out.log"; exit 1; }
LA="$HOME/Library/LaunchAgents"
env_of() { /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$2" "$LA/ai.manaflow.chief-brain.$1.plist" 2>/dev/null || true; }
brain="$HOME/.cmux/brains/chief"
fail() { echo "FAIL: $*"; exit 1; }
[[ "$(env_of acpmux ACPMUX_HOME)" == "$brain/acpmux" ]] || fail "acpmux agent ACPMUX_HOME"
[[ "$(env_of daemon ACPMUX_HOME)" == "$brain/acpmux" ]] || fail "daemon agent has no ACPMUX_HOME=$brain/acpmux (got '$(env_of daemon ACPMUX_HOME)')"
[[ "$(env_of daemon CMUX_TUI_CHIEF_TOOLS_SOCKET)" == "$brain/mux/optchat/tools.sock" ]] || fail "daemon agent has no CMUX_TUI_CHIEF_TOOLS_SOCKET (got '$(env_of daemon CMUX_TUI_CHIEF_TOOLS_SOCKET)')"
[[ "$(env_of host OPTCHAT_ACPMUX_SUPERVISED)" == "1" ]] || fail "host agent OPTCHAT_ACPMUX_SUPERVISED"
# Subagents and the Chief run `cmux` from $BRAIN/bin first on PATH (cmux_env.rs pins it there
# only when the CLI sits next to optchat-chief). Without it they ran an older `cmux` from ~/bin
# that ignores CMUX_TUI_SOCKET, so `cmux identify` failed inside subagents (cx-ebm.40).
[[ -x "$brain/bin/cmux" ]] || fail "no cmux CLI in $brain/bin"
[[ -z "$(env_of host MUX_HARNESS)" ]] || fail "host agent pins MUX_HARNESS='$(env_of host MUX_HARNESS)'; the default harness is acpmux's"
PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" "$here/install.sh" --optchat-chief "$tmp/bin/optchat-chief" --cmux-tui "$tmp/bin/cmux-tui" \
  --cmux "$tmp/bin/cmux" --acpmux "$tmp/bin/acpmux" --harness codex --no-start > "$tmp/out.log" 2>&1 || { cat "$tmp/out.log"; exit 1; }
[[ "$(env_of host MUX_HARNESS)" == "codex" ]] || fail "--harness codex is not the host's MUX_HARNESS (got '$(env_of host MUX_HARNESS)')"
echo "install.test.sh: ok"
