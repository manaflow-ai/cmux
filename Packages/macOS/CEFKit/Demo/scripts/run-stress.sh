#!/bin/zsh
# End-to-end stress entry point. Launches CEFDemo with the CDP endpoint and
# app-side churn (CEFDEMO_STRESS: resize + profile switching + DevTools
# dock/undock cycling), waits for readiness, then runs the CDP storm
# (navigation, typing, clicks, scrolls, drags). Fails if the app crashes or
# any page stops answering.
#
# Usage: run-stress.sh [seconds]   (env: CEFDEMO_DEBUG_PORT, CEFDEMO_STRESS_MODE)
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

pkill -9 -f 'CEFDemo.app/Contents/MacOS' 2>/dev/null || true
sleep 1
rm -rf "$HOME/Library/Application Support/CEFDemo"

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
pkill -9 -f 'CEFDemo.app/Contents/MacOS' 2>/dev/null || true
echo "log: $LOG"
exit $STATUS
