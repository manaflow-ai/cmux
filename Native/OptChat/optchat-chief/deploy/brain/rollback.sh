#!/usr/bin/env bash
# Stops and removes the Chief brain's LaunchAgents (install.sh). Keeps
# $BRAIN (memory, install key, logs) unless --purge-binaries; the memory and
# the install key are never deleted here. Touches nothing else: not the
# subrouter, not com.acpmux.daemon, not ~/.local/bin.
#
# usage: rollback.sh [--brain DIR] [--purge-binaries]
set -euo pipefail
BRAIN="${HOME}/.cmux/brains/chief" PURGE=0
while (($#)); do
  case "$1" in
    --brain) BRAIN="$2"; shift 2 ;;
    --purge-binaries) PURGE=1; shift ;;
    *) echo "rollback.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
LA="$HOME/Library/LaunchAgents"
P=ai.manaflow.chief-brain
domains=("gui/$(id -u)" "user/$(id -u)")
bootout() { # label
  local domain
  for domain in "${domains[@]}"; do
    launchctl bootout "$domain/$P.$1" 2>/dev/null && echo "stopped $P.$1 ($domain)" || true
  done
}
# The host first: no new turn starts. Then the supervised acpmux's own shutdown ends every
# session and agent process it started (agent hosts, optchat-chief mcp); booting out its
# LaunchAgent alone would leave them running. Then its LaunchAgent and the daemon.
bootout host
if [[ -x "$BRAIN/bin/acpmux" ]]; then
  ACPMUX_HOME="$BRAIN/acpmux" ACPMUX_SOCKET="$BRAIN/acpmux/acpmux.sock" "$BRAIN/bin/acpmux" daemon shutdown 2>/dev/null \
    && echo "acpmux: daemon shutdown ended its sessions" || echo "acpmux: no daemon answered (already stopped)"
fi
bootout acpmux
bootout daemon
# Verify: no process of this user runs from $BRAIN/bin. Only this user's processes, only that path.
left="$(pgrep -U "$(id -u)" -f "$BRAIN/bin/" || true)"
if [[ -n "$left" ]]; then
  echo "rollback.sh: still running from $BRAIN/bin after shutdown; stopping them:" >&2
  ps -o pid=,command= -p "$(echo $left | tr ' ' ',')" >&2 || true
  kill $left 2>/dev/null || true
  sleep 2
  left="$(pgrep -U "$(id -u)" -f "$BRAIN/bin/" || true)"
  [[ -z "$left" ]] || { echo "rollback.sh: processes still running from $BRAIN/bin: $left" >&2; exit 1; }
fi
echo "no brain process left under $BRAIN/bin"
for l in host acpmux daemon; do rm -f "$LA/$P.$l.plist"; done
((PURGE)) && rm -rf "$BRAIN/bin"
echo "removed the LaunchAgents; kept $BRAIN/mux (memory), $BRAIN/cloud (install key) and $BRAIN/logs"
echo "to stop the brain's cloud access at once, revoke its install in cmux (Settings > Devices) or with install.revoke"
