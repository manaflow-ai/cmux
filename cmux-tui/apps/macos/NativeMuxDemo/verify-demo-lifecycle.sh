#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TUI_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
RUN_DEMO="$SCRIPT_DIR/run-demo.sh"
CMUX_TUI="$TUI_ROOT/target/native-mux-demo/rust-build/debug/cmux-tui"
APP_PROCESS_TOKEN="target/native-mux-demo/NativeMuxDemo.app/Contents/MacOS/NativeMuxDemo"
HOST_PROCESS_TOKEN="$CMUX_TUI __terminal-host --bootstrap-stdio"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-native-mux-lifecycle.XXXXXX")"
LAUNCH_LOG="$TEST_ROOT/launcher.log"
LAUNCHER_PID=""
APP_PID=""
APP_PIDS_BEFORE=""
HOST_PIDS_BEFORE=""

matching_pids() {
  local token="$1"
  pgrep -f "$token" | sort -n | tr '\n' ' ' || true
}

new_pids() {
  local token="$1"
  local previous="$2"
  local pid
  for pid in $(matching_pids "$token"); do
    if [[ " $previous " != *" $pid "* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

stop_validated_pid() {
  local pid="$1"
  local expected="$2"
  local command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$command" == *"$expected"* ]]; then
    kill "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  set +e
  if [[ -n "$APP_PID" ]]; then
    stop_validated_pid "$APP_PID" "$APP_PROCESS_TOKEN"
  fi
  if [[ -n "$LAUNCHER_PID" ]]; then
    stop_validated_pid "$LAUNCHER_PID" "$RUN_DEMO"
    wait "$LAUNCHER_PID" 2>/dev/null
  fi
  for pid in $(new_pids "$HOST_PROCESS_TOKEN" "$HOST_PIDS_BEFORE"); do
    stop_validated_pid "$pid" "$HOST_PROCESS_TOKEN"
  done
  rm -f -- "$LAUNCH_LOG"
  rmdir "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for artifact in "$RUN_DEMO" "$CMUX_TUI"; do
  if [[ ! -x "$artifact" ]]; then
    echo "Missing reusable demo artifact: $artifact" >&2
    exit 1
  fi
done

APP_PIDS_BEFORE="$(matching_pids "$APP_PROCESS_TOKEN")"
HOST_PIDS_BEFORE="$(matching_pids "$HOST_PROCESS_TOKEN")"

"$RUN_DEMO" --reuse-build --swift-only >"$LAUNCH_LOG" 2>&1 &
LAUNCHER_PID=$!

ready=0
for _ in $(seq 1 900); do
  if grep -q '^Ready\.' "$LAUNCH_LOG"; then
    ready=1
    break
  fi
  if ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    echo "Demo launcher exited before becoming ready:" >&2
    sed -n '1,220p' "$LAUNCH_LOG" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$ready" != "1" ]]; then
  echo "Demo launcher did not become ready within 90 seconds:" >&2
  sed -n '1,220p' "$LAUNCH_LOG" >&2
  exit 1
fi

for _ in $(seq 1 100); do
  APP_PID="$(new_pids "$APP_PROCESS_TOKEN" "$APP_PIDS_BEFORE" | head -1)"
  [[ -n "$APP_PID" ]] && break
  sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
  echo "Could not identify the NativeMuxDemo process." >&2
  exit 1
fi

stop_validated_pid "$APP_PID" "$APP_PROCESS_TOKEN"
APP_PID=""

for _ in $(seq 1 200); do
  if ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$LAUNCHER_PID" 2>/dev/null; then
  echo "Demo launcher did not exit after NativeMuxDemo closed." >&2
  exit 1
fi
wait "$LAUNCHER_PID"
LAUNCHER_PID=""

SURVIVORS="$(new_pids "$HOST_PROCESS_TOKEN" "$HOST_PIDS_BEFORE")"
if [[ -n "$SURVIVORS" ]]; then
  echo "Demo cleanup leaked terminal-host processes: $(printf '%s' "$SURVIVORS" | tr '\n' ' ')" >&2
  exit 1
fi

echo "NativeMuxDemo lifecycle verification passed: no terminal hosts survived app exit."
