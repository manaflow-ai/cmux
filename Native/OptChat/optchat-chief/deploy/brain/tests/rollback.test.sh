#!/usr/bin/env bash
# rollback.sh stops the brain's acpmux sessions (agent hosts, optchat-chief mcp) through the
# supervised acpmux's own `daemon shutdown`, after the host stops and before its LaunchAgent goes,
# and leaves no process running from $BRAIN/bin (2026-10-06: a rollback left 10 behind).
# Fakes: launchctl on PATH logs its calls; $BRAIN/bin/acpmux logs `daemon shutdown` and ends the
# throwaway session process, as the real daemon does. Nothing outside the temp dir is touched.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'kill "${session:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export HOME="$tmp/home" LOG="$tmp/calls.log"
BRAIN="$tmp/brain"
mkdir -p "$HOME/Library/LaunchAgents" "$BRAIN/bin" "$BRAIN/acpmux" "$tmp/path"
: > "$LOG"
cat > "$tmp/path/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LOG"
SH
# A throwaway acpmux session: a process started from $BRAIN/bin, as acpmux __agent-host is.
cat > "$BRAIN/bin/agent-host" <<'SH'
#!/usr/bin/env bash
exec -a "$0" sleep 300
SH
# Mode (file $MODE): ok (ends the session), old (an acpmux before --end-agents: usage error,
# exit 2; its plain shutdown ends the session), none (no daemon answers: exit 1).
export MODE="$tmp/mode"; echo ok > "$MODE"
cat > "$BRAIN/bin/acpmux" <<'SH'
#!/usr/bin/env bash
echo "acpmux $* ACPMUX_HOME=$ACPMUX_HOME" >> "$LOG"
case "$(cat "$MODE")" in
  old) [[ "$*" == *--end-agents* ]] && exit 2 ;;
  none) exit 1 ;;
esac
pkill -U "$(id -u)" -f "$(dirname "$0")/agent-host" || true
SH
chmod 755 "$tmp/path/launchctl" "$BRAIN/bin/agent-host" "$BRAIN/bin/acpmux"
"$BRAIN/bin/agent-host" &
session=$!
PATH="$tmp/path:$PATH" "$here/rollback.sh" --brain "$BRAIN" > "$tmp/out.log" 2>&1
fail() { echo "FAIL: $*"; cat "$LOG" "$tmp/out.log"; exit 1; }
grep -q "^acpmux daemon shutdown --end-agents ACPMUX_HOME=$BRAIN/acpmux$" "$LOG" || fail "no acpmux daemon shutdown --end-agents with the brain's ACPMUX_HOME"
line() { grep -n "$1" "$LOG" | head -1 | cut -d: -f1; }
host=$(line "bootout gui/[0-9]*/ai.manaflow.chief-brain.host")
shutdown=$(line "acpmux daemon shutdown --end-agents")
agent=$(line "bootout gui/[0-9]*/ai.manaflow.chief-brain.acpmux")
[[ -n "$host" && -n "$agent" && "$host" -lt "$shutdown" && "$shutdown" -lt "$agent" ]] || fail "order: host bootout, then acpmux shutdown, then the acpmux LaunchAgent"
sleep 0.5
if kill -0 "$session" 2>/dev/null; then fail "a process from \$BRAIN/bin is still running"; fi
grep -q "no brain process left" "$tmp/out.log" || fail "rollback did not verify that no brain process is left"
# An older acpmux (exit 2 on --end-agents): the plain shutdown runs and the rollback goes on.
# No daemon at all (exit 1): the rollback still boots out the acpmux and daemon agents.
for mode in old none; do
  echo "$mode" > "$MODE"; : > "$LOG"
  PATH="$tmp/path:$PATH" "$here/rollback.sh" --brain "$BRAIN" > "$tmp/out.$mode.log" 2>&1 || fail "rollback exited non-zero with acpmux mode $mode"
  if [[ "$mode" == old ]]; then grep -q "^acpmux daemon shutdown ACPMUX_HOME=$BRAIN/acpmux$" "$LOG" || fail "no plain fallback shutdown for an older acpmux"; fi
  grep -q "bootout gui/[0-9]*/ai.manaflow.chief-brain.acpmux" "$LOG" || fail "mode $mode: the acpmux LaunchAgent was not booted out"
  grep -q "bootout gui/[0-9]*/ai.manaflow.chief-brain.daemon" "$LOG" || fail "mode $mode: the daemon LaunchAgent was not booted out"
done
echo "rollback.test.sh: ok"
