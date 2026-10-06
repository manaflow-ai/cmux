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
for domain in "gui/$(id -u)" "user/$(id -u)"; do
  for l in host acpmux daemon; do
    launchctl bootout "$domain/$P.$l" 2>/dev/null && echo "stopped $P.$l ($domain)" || true
  done
done
for l in host acpmux daemon; do rm -f "$LA/$P.$l.plist"; done
((PURGE)) && rm -rf "$BRAIN/bin"
echo "removed the LaunchAgents; kept $BRAIN/mux (memory), $BRAIN/cloud (install key) and $BRAIN/logs"
echo "to stop the brain's cloud access at once, revoke its install in cmux (Settings > Devices) or with install.revoke"
