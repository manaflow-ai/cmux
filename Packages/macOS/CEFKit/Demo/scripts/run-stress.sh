#!/bin/zsh
# End-to-end stress entry point. Launches CEFDemo with the CDP endpoint and
# app-side churn (CEFDEMO_STRESS: resize + profile switching + DevTools
# dock/undock cycling), waits for readiness, then runs the CDP storm
# (navigation, typing, clicks, scrolls, drags). Fails if the app crashes or
# any page stops answering.
#
# Usage: run-stress.sh [seconds]
# Env: CEFDEMO_DEBUG_PORT, CEFDEMO_STRESS_MODE, CEFDEMO_STRESS_WIPE=1 to also
#      delete the persistent CEFDemo Application Support state (profiles,
#      cookies, extension state) for a clean-slate run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CEFDEMO_DEBUG_PORT:-19230}"
DURATION="${1:-75}"
MODE="${CEFDEMO_STRESS_MODE:-all}"
APP="$ROOT/DerivedData/Build/Products/Debug/CEFDemo.app/Contents/MacOS/CEFDemo"

if [[ ! -x "$APP" ]]; then
  echo "CEFDemo.app missing; run Demo/scripts/build.sh first" >&2
  exit 1
fi

# Kill only leftovers of THIS checkout's build (they hold the CDP port);
# never other CEFDemo builds or manual sessions from other checkouts.
pkill -9 -f "$APP" 2>/dev/null || true
sleep 1
# Deleting profiles/cookies/extension state is destructive; opt in.
if [[ "${CEFDEMO_STRESS_WIPE:-0}" == "1" ]]; then
  echo "CEFDEMO_STRESS_WIPE=1: removing $HOME/Library/Application Support/CEFDemo"
  rm -rf "$HOME/Library/Application Support/CEFDemo"
fi

LOG="$(mktemp /tmp/cefdemo-stress.XXXXXX)"
CEFDEMO_DEBUG_PORT="$PORT" CEFDEMO_AUTOTEST=1 CEFDEMO_STRESS=1 CEFDEMO_STRESS_MODE="$MODE" \
  "$APP" > "$LOG" 2>&1 &
APP_PID=$!

ready=0
for _ in {1..80}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "app died during startup; log:" >&2
    grep -E 'FATAL|CEFDemo:' "$LOG" | head -5 >&2
    exit 1
  fi
  if curl -s -m 1 "http://127.0.0.1:$PORT/json" > /dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
if [[ "$ready" != "1" ]]; then
  echo "CDP endpoint never came up; log tail:" >&2
  tail -5 "$LOG" >&2
  exit 1
fi
sleep 5  # let all profile browsers finish creating

bun "$ROOT/scripts/stress.mjs" "$PORT" "$DURATION"
STATUS=$?

if kill -0 "$APP_PID" 2>/dev/null; then
  echo "app alive after stress (mode=$MODE, ${DURATION}s)"
else
  echo "APP DIED during stress; log:" >&2
  grep -m3 -E 'FATAL' "$LOG" >&2
  STATUS=1
fi
# Tear down only the instance this run launched.
kill -9 "$APP_PID" 2>/dev/null || true
echo "log: $LOG"
exit $STATUS
