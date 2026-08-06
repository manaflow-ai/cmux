#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_REMOTE_DEMO="$SCRIPT_DIR/run-remote-demo.sh"
REMOTE_HOST="${1:-cmux-lawrence}"
RUNS="${2:-3}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-native-remote-lifecycle.XXXXXX")"
LOCAL_TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
APP_PROCESS_SUFFIX="/NativeMuxDemo.app/Contents/MacOS/NativeMuxDemo"
LAUNCHER_PID=""
APP_PID=""
ATTACH_PID=""
ATTACH_FD_OPEN=0

if [[ $# -gt 2 || ! "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: verify-remote-demo-lifecycle.sh [ssh-host] [runs]" >&2
  exit 2
fi

cleanup() {
  set +e
  if [[ "$ATTACH_FD_OPEN" == "1" ]]; then
    exec 8>&-
    ATTACH_FD_OPEN=0
  fi
  if [[ -n "$ATTACH_PID" ]] && kill -0 "$ATTACH_PID" 2>/dev/null; then
    kill "$ATTACH_PID" 2>/dev/null
    wait "$ATTACH_PID" 2>/dev/null
  fi
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

TOTAL_RUNS=$((RUNS + 1))
for run in $(seq 1 "$TOTAL_RUNS"); do
  OWNER_LOSS=0
  if (( run > RUNS )); then
    OWNER_LOSS=1
  fi
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

  ATTACH_LOG="$TEST_ROOT/attach-$run.log"
  ATTACH_PIPE="$TEST_ROOT/attach-$run.pipe"
  ATTACH_COMMAND="$(cmux_remote_quote_command \
    "$REMOTE_ROOT/cmux-tui" attach --socket "$REMOTE_ROOT/mux.sock")"
  /usr/bin/mkfifo "$ATTACH_PIPE"
  # shellcheck disable=SC2029  # Arguments are escaped above.
  ssh -tt "${CMUX_REMOTE_SSH_OPTIONS[@]}" "$REMOTE_HOST" "$ATTACH_COMMAND" \
    <"$ATTACH_PIPE" >"$ATTACH_LOG" 2>&1 &
  ATTACH_PID=$!
  exec 8>"$ATTACH_PIPE"
  ATTACH_FD_OPEN=1
  attach_ready=0
  for _ in $(seq 1 100); do
    if [[ -s "$ATTACH_LOG" ]] && kill -0 "$ATTACH_PID" 2>/dev/null; then
      attach_ready=1
      break
    fi
    if ! kill -0 "$ATTACH_PID" 2>/dev/null; then
      echo "Remote demo run $run lost its direct terminal attach before cleanup." >&2
      sed -n '1,80p' "$ATTACH_LOG" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ "$attach_ready" != "1" ]]; then
    echo "Remote demo run $run did not establish its direct terminal attach." >&2
    exit 1
  fi

  LOCAL_RUN_ROOT="${APP_BUNDLE%/NativeMuxDemo.app}"
  if [[ "$OWNER_LOSS" == "1" ]]; then
    kill -KILL "$LAUNCHER_PID"
    set +e
    wait "$LAUNCHER_PID" 2>/dev/null
    LAUNCHER_STATUS=$?
    set -e
    if (( LAUNCHER_STATUS != 137 )); then
      echo "Remote demo owner-loss run exited with $LAUNCHER_STATUS instead of SIGKILL status 137." >&2
      exit 1
    fi
    LAUNCHER_PID=""
  else
    kill "$APP_PID"
    APP_PID=""
  fi

  for _ in $(seq 1 300); do
    if [[ "$OWNER_LOSS" == "1" ]]; then
      if ! cmux_remote_run /bin/test -e "$REMOTE_ROOT" >/dev/null 2>&1; then
        break
      fi
    elif ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [[ "$OWNER_LOSS" != "1" ]] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    echo "Remote demo run $run did not stop after its app closed." >&2
    exit 1
  fi
  if [[ "$OWNER_LOSS" != "1" ]] && ! wait "$LAUNCHER_PID"; then
    echo "Remote demo run $run failed during cleanup:" >&2
    sed -n '1,220p' "$LAUNCH_LOG" >&2
    exit 1
  fi
  LAUNCHER_PID=""

  if [[ "$ATTACH_FD_OPEN" == "1" ]]; then
    exec 8>&-
    ATTACH_FD_OPEN=0
  fi
  for _ in $(seq 1 100); do
    kill -0 "$ATTACH_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$ATTACH_PID" 2>/dev/null; then
    echo "Remote demo run $run left its direct terminal attach running." >&2
    exit 1
  fi
  if ! wait "$ATTACH_PID"; then
    echo "Remote demo run $run did not close its direct terminal attach cleanly:" >&2
    sed -n '1,80p' "$ATTACH_LOG" >&2
    exit 1
  fi
  ATTACH_PID=""

  if cmux_remote_run /bin/test -e "$REMOTE_ROOT" >/dev/null 2>&1; then
    echo "Remote demo run $run left $REMOTE_ROOT behind." >&2
    exit 1
  fi
  REMOTE_PROCESSES="$(cmux_remote_run /bin/ps -axo command=)"
  if grep -F "$REMOTE_ROOT/" <<<"$REMOTE_PROCESSES" >/dev/null; then
    echo "Remote demo run $run left a process under $REMOTE_ROOT running." >&2
    grep -F "$REMOTE_ROOT/" <<<"$REMOTE_PROCESSES" >&2
    exit 1
  fi

  if [[ "$OWNER_LOSS" == "1" ]]; then
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill "$APP_PID" 2>/dev/null || true
      for _ in $(seq 1 100); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.1
      done
    fi
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -KILL "$APP_PID" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.1
      done
    fi
    if kill -0 "$APP_PID" 2>/dev/null; then
      echo "Remote demo owner-loss run could not stop its isolated app." >&2
      exit 1
    fi
    APP_PID=""
    case "$LOCAL_RUN_ROOT" in
      "$LOCAL_TEMP_PARENT"/cmux-native-remote-client.*) rm -rf -- "$LOCAL_RUN_ROOT" ;;
    esac
    echo "Remote demo forced owner-loss run passed."
  else
    echo "Remote demo lifecycle run $run/$RUNS passed with a direct attach."
  fi
done

echo "Remote NativeMuxDemo lifecycle verification passed $RUNS normal runs and one forced owner-loss run."
