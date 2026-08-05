#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_REMOTE_DEMO="$SCRIPT_DIR/run-remote-demo.sh"
REMOTE_HOST="${1:-cmux-lawrence}"
RUNS="${2:-3}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-native-remote-lifecycle.XXXXXX")"
APP_PROCESS_SUFFIX="/NativeMuxDemo.app/Contents/MacOS/NativeMuxDemo"
LAUNCHER_PID=""
APP_PID=""

if [[ $# -gt 2 || ! "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: verify-remote-demo-lifecycle.sh [ssh-host] [runs]" >&2
  exit 2
fi

cleanup() {
  set +e
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
  fi
  if [[ -n "$LAUNCHER_PID" ]] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    kill "$LAUNCHER_PID" 2>/dev/null
    wait "$LAUNCHER_PID" 2>/dev/null
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

matching_app_pids() {
  pgrep -f "$APP_PROCESS_SUFFIX" | sort -n | tr '\n' ' ' || true
}

new_app_pid() {
  local previous="$1"
  local pid
  local command
  for pid in $(matching_app_pids); do
    if [[ " $previous " == *" $pid "* ]]; then
      continue
    fi
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == */cmux-native-remote-client.*"$APP_PROCESS_SUFFIX" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# shellcheck source=remote-command.sh
source "$SCRIPT_DIR/remote-command.sh"
CMUX_REMOTE_SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=8)
CMUX_REMOTE_HOST="$REMOTE_HOST"
CMUX_REMOTE_RUN_ID="verify"
CMUX_REMOTE_TEMP_ROOT="$TEST_ROOT"

for run in $(seq 1 "$RUNS"); do
  LAUNCH_LOG="$TEST_ROOT/launcher-$run.log"
  APP_PIDS_BEFORE="$(matching_app_pids)"
  "$RUN_REMOTE_DEMO" "$REMOTE_HOST" >"$LAUNCH_LOG" 2>&1 &
  LAUNCHER_PID=$!

  ready=0
  for _ in $(seq 1 900); do
    if grep -q '^Ready\.' "$LAUNCH_LOG"; then
      ready=1
      break
    fi
    if ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
      echo "Remote demo run $run exited before becoming ready:" >&2
      sed -n '1,220p' "$LAUNCH_LOG" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ "$ready" != "1" ]]; then
    echo "Remote demo run $run did not become ready within 90 seconds:" >&2
    sed -n '1,220p' "$LAUNCH_LOG" >&2
    exit 1
  fi

  for _ in $(seq 1 100); do
    APP_PID="$(new_app_pid "$APP_PIDS_BEFORE" || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
  done
  if [[ -z "$APP_PID" ]]; then
    echo "Remote demo run $run did not expose its isolated app process." >&2
    exit 1
  fi

  APP_COMMAND="$(ps -p "$APP_PID" -o command=)"
  APP_BUNDLE="${APP_COMMAND%/Contents/MacOS/NativeMuxDemo}"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_BUNDLE/Contents/Info.plist")"
  RUN_ID="${BUNDLE_ID##*.}"
  REMOTE_ROOT="/tmp/cmux-native-remote-demo.$RUN_ID"
  if [[ ! "$RUN_ID" =~ ^[0-9a-f]{12}$ ]] \
    || ! cmux_remote_run /bin/test -S "$REMOTE_ROOT/mux.sock" >/dev/null; then
    echo "Remote demo run $run did not expose a live isolated mux socket." >&2
    exit 1
  fi

  kill "$APP_PID"
  APP_PID=""
  for _ in $(seq 1 300); do
    if ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    echo "Remote demo run $run did not stop after its app closed." >&2
    exit 1
  fi
  if ! wait "$LAUNCHER_PID"; then
    echo "Remote demo run $run failed during cleanup:" >&2
    sed -n '1,220p' "$LAUNCH_LOG" >&2
    exit 1
  fi
  LAUNCHER_PID=""

  if cmux_remote_run /bin/test -e "$REMOTE_ROOT" >/dev/null 2>&1; then
    echo "Remote demo run $run left $REMOTE_ROOT behind." >&2
    exit 1
  fi
  echo "Remote demo lifecycle run $run/$RUNS passed."
done

echo "Remote NativeMuxDemo lifecycle verification passed $RUNS consecutive runs."
