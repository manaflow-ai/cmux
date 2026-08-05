#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TUI_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
REMOTE_HOST="${1:-cmux-lawrence}"

if [[ $# -gt 1 || "$REMOTE_HOST" == -* \
  || ! "$REMOTE_HOST" =~ ^[A-Za-z0-9._@-]+$ ]]; then
  echo "Usage: run-remote-demo.sh [ssh-host]" >&2
  exit 2
fi

for command in codesign jq open openssl perl pgrep scp shasum ssh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Remote NativeMuxDemo needs $command on PATH." >&2
    exit 1
  fi
done

DEMO_BUILD_ROOT="$TUI_ROOT/target/native-mux-demo"
CMUX_TUI="$DEMO_BUILD_ROOT/rust-build/debug/cmux-tui"
APP_BUNDLE="$DEMO_BUILD_ROOT/NativeMuxDemo.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NativeMuxDemo"
for artifact in "$CMUX_TUI" "$APP_EXECUTABLE"; do
  if [[ ! -x "$artifact" ]]; then
    echo "Reusable demo artifact is missing: $artifact" >&2
    echo "Run run-demo.sh without --reuse-build once, then retry." >&2
    exit 1
  fi
done

LOCAL_OS="$(uname -s)"
LOCAL_ARCH="$(uname -m)"
TEMP_PARENT="${TMPDIR:-/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
TEMP_PARENT="$(cd "$TEMP_PARENT" && pwd -P)"
LOCAL_ROOT="$(mktemp -d "$TEMP_PARENT/cmux-native-remote-client.XXXXXX")"
LOCAL_ROOT="$(cd "$LOCAL_ROOT" && pwd -P)"
RUN_APP_BUNDLE="$LOCAL_ROOT/NativeMuxDemo.app"
RUN_APP_EXECUTABLE="$RUN_APP_BUNDLE/Contents/MacOS/NativeMuxDemo"
INVITATION_FILE="$LOCAL_ROOT/invitation.txt"
DAEMON_LOG="$LOCAL_ROOT/remote-daemon.log"
RUN_ID="$(openssl rand -hex 6)"
SESSION="native-remote-$RUN_ID"
REMOTE_ROOT="/tmp/cmux-native-remote-demo.$RUN_ID"
REMOTE_BIN="$REMOTE_ROOT/cmux-tui"
REMOTE_MUX_SOCKET="$REMOTE_ROOT/mux.sock"
REMOTE_MUX_STATE="$REMOTE_ROOT/mux-state"
REMOTE_ADMIN_SOCKET="$REMOTE_ROOT/admin.sock"
REMOTE_LINK_SOCKET="$REMOTE_ROOT/link.sock"
REMOTE_STATE="$REMOTE_ROOT/remote-state"
REMOTE_DAEMON_PID_FILE="$REMOTE_ROOT/daemon.pid"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=8)
SSH_DAEMON_PID=""
REMOTE_DAEMON_PID=""
OPEN_PID=""
APP_PID=""
REMOTE_CREATED=0
CLEANUP_STARTED=0

# shellcheck source=remote-command.sh
source "$SCRIPT_DIR/remote-command.sh"
CMUX_REMOTE_SSH_OPTIONS=("${SSH_OPTIONS[@]}")
CMUX_REMOTE_HOST="$REMOTE_HOST"
CMUX_REMOTE_RUN_ID="$RUN_ID"
CMUX_REMOTE_TEMP_ROOT="$LOCAL_ROOT"

remote_command() {
  cmux_remote_run "$@"
}

remote_daemon_alive() {
  [[ "$REMOTE_DAEMON_PID" =~ ^[1-9][0-9]*$ ]] \
    && remote_command /bin/kill -0 "$REMOTE_DAEMON_PID" >/dev/null 2>&1
}

read_remote_daemon_pid() {
  local candidate
  candidate="$(remote_command /bin/cat "$REMOTE_DAEMON_PID_FILE" 2>/dev/null || true)"
  if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
    REMOTE_DAEMON_PID="$candidate"
    return 0
  fi
  return 1
}

wait_for_remote_daemon_exit() {
  local attempts="$1"
  # shellcheck disable=SC2016  # The inner shell expands these positional parameters remotely.
  local command='pid=$1; attempts=$2; while kill -0 "$pid" 2>/dev/null && [ "$attempts" -gt 0 ]; do attempts=$((attempts - 1)); sleep 0.1; done; ! kill -0 "$pid" 2>/dev/null'
  remote_command /bin/sh -c "$command" sh "$REMOTE_DAEMON_PID" "$attempts" \
    >/dev/null 2>&1
}

signal_remote_daemon() {
  local signal="$1"
  local command
  command="$(remote_command /bin/ps -p "$REMOTE_DAEMON_PID" -o command= 2>/dev/null || true)"
  if [[ "$command" != "$REMOTE_BIN daemon --session $SESSION "* ]]; then
    echo "Refusing to signal unexpected remote process $REMOTE_DAEMON_PID: $command" >&2
    return 1
  fi
  remote_command /bin/kill "-$signal" "$REMOTE_DAEMON_PID" >/dev/null 2>&1
}

report_remote_owner_state() {
  if remote_daemon_alive; then
    echo "The remote daemon process is still running." >&2
  else
    echo "The remote daemon process exited." >&2
  fi
  if remote_command /bin/test -S "$REMOTE_MUX_SOCKET" >/dev/null 2>&1; then
    echo "The remote mux socket still exists." >&2
  else
    echo "The remote mux socket disappeared." >&2
  fi
  if remote_command /bin/test -S "$REMOTE_ADMIN_SOCKET" >/dev/null 2>&1; then
    echo "The remote admin socket still exists." >&2
  else
    echo "The remote admin socket disappeared." >&2
  fi
}

find_run_app_pid() {
  local command
  local pid
  for pid in $(pgrep -f "$RUN_APP_EXECUTABLE" 2>/dev/null || true); do
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$RUN_APP_EXECUTABLE" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

invitation_id() {
  local invitation="$1"
  local encoded="${invitation#cmux://enroll/}"
  local standard
  if [[ "$encoded" == "$invitation" ]]; then
    return 1
  fi
  standard="$(printf '%s' "$encoded" | sed 'y#_-#/+#')"
  while (( ${#standard} % 4 != 0 )); do standard="${standard}="; done
  printf '%s' "$standard" | openssl base64 -d -A | jq -er '.id'
}

remote_host_pids() {
  remote_command /usr/bin/pgrep -f \
    "^$REMOTE_BIN __terminal-host --bootstrap-stdio$" 2>/dev/null || true
}

close_remote_terminals() {
  local terminals
  local terminal_id
  terminals="$(
    remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" terminal list --json \
      2>/dev/null || true
  )"
  if ! printf '%s' "$terminals" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return 0
  fi
  for terminal_id in $(printf '%s' "$terminals" | jq -r '.[].id'); do
    remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
      terminal "$terminal_id" close --json >/dev/null 2>&1 || true
  done
}

stop_remote_hosts() {
  local host_pids="$1"
  local host_pid
  local command
  local expected="$REMOTE_BIN __terminal-host --bootstrap-stdio"
  for _ in $(seq 1 10); do
    local alive=0
    for host_pid in $host_pids; do
      if remote_command /bin/kill -0 "$host_pid" >/dev/null 2>&1; then
        alive=$((alive + 1))
      fi
    done
    (( alive == 0 )) && return 0
    sleep 0.1
  done
  for host_pid in $host_pids; do
    command="$(remote_command /bin/ps -p "$host_pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$expected" ]]; then
      remote_command /bin/kill "$host_pid" >/dev/null 2>&1 || true
    fi
  done
}

cleanup() {
  local exit_status=$?
  if [[ "$CLEANUP_STARTED" == "1" ]]; then
    return
  fi
  CLEANUP_STARTED=1
  set +e
  if [[ -z "$APP_PID" ]]; then
    APP_PID="$(find_run_app_pid || true)"
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then
    kill "$OPEN_PID" 2>/dev/null
    wait "$OPEN_PID" 2>/dev/null
  fi
  if [[ "$REMOTE_CREATED" == "1" ]]; then
    if [[ -z "$REMOTE_DAEMON_PID" ]]; then
      read_remote_daemon_pid || true
    fi
    local host_pids
    host_pids="$(remote_host_pids)"
    close_remote_terminals
    stop_remote_hosts "$host_pids"
    remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
      session current shutdown --force --json >/dev/null 2>&1 || true
    if remote_daemon_alive && ! wait_for_remote_daemon_exit 100; then
      signal_remote_daemon TERM || true
      wait_for_remote_daemon_exit 50 || true
    fi
    if remote_daemon_alive; then
      signal_remote_daemon KILL || true
      wait_for_remote_daemon_exit 20 || true
    fi
  fi
  if [[ -n "$SSH_DAEMON_PID" ]] && kill -0 "$SSH_DAEMON_PID" 2>/dev/null; then
    kill "$SSH_DAEMON_PID" 2>/dev/null
    wait "$SSH_DAEMON_PID" 2>/dev/null
  fi
  if [[ "$REMOTE_CREATED" == "1" \
    && "$REMOTE_ROOT" == /tmp/cmux-native-remote-demo.* ]]; then
    if remote_daemon_alive; then
      echo "Refusing to remove remote state while daemon $REMOTE_DAEMON_PID is alive." >&2
      exit_status=1
    else
      remote_command /bin/rm -rf -- "$REMOTE_ROOT" >/dev/null 2>&1 || exit_status=1
    fi
  fi
  if (( exit_status != 0 )) && [[ -s "$DAEMON_LOG" ]]; then
    echo "Remote daemon log from the failed run:" >&2
    sed -n '1,220p' "$DAEMON_LOG" >&2
  fi
  if [[ "$LOCAL_ROOT" == "$TEMP_PARENT"/cmux-native-remote-client.* ]]; then
    rm -rf -- "$LOCAL_ROOT"
  fi
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "Checking $REMOTE_HOST..."
REMOTE_OS="$(remote_command uname -s)"
REMOTE_ARCH="$(remote_command uname -m)"
if [[ "$REMOTE_OS" != "$LOCAL_OS" || "$REMOTE_ARCH" != "$LOCAL_ARCH" ]]; then
  echo "The reusable binary is $LOCAL_OS/$LOCAL_ARCH, but $REMOTE_HOST is $REMOTE_OS/$REMOTE_ARCH." >&2
  exit 1
fi

echo "Preparing an isolated local copy of NativeMuxDemo..."
/usr/bin/ditto "$APP_BUNDLE" "$RUN_APP_BUNDLE"
if [[ ! -x "$RUN_APP_EXECUTABLE" ]]; then
  echo "The isolated NativeMuxDemo copy is incomplete." >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier com.cmux.NativeMuxDemo.remote.$RUN_ID" \
  "$RUN_APP_BUNDLE/Contents/Info.plist"
if ! codesign --force --deep --sign - "$RUN_APP_BUNDLE" >/dev/null 2>&1 \
  || ! codesign --verify --deep --strict "$RUN_APP_BUNDLE"; then
  echo "The isolated NativeMuxDemo copy could not be signed." >&2
  exit 1
fi

echo "Installing this PR's exact cmux-tui in an isolated directory on $REMOTE_HOST..."
remote_command /bin/mkdir -m 700 "$REMOTE_ROOT"
REMOTE_CREATED=1
scp -q "${SSH_OPTIONS[@]}" "$CMUX_TUI" "$REMOTE_HOST:$REMOTE_BIN"
remote_command /bin/chmod 700 "$REMOTE_BIN"
LOCAL_HASH="$(shasum -a 256 "$CMUX_TUI" | awk '{print $1}')"
REMOTE_HASH="$(remote_command /usr/bin/shasum -a 256 "$REMOTE_BIN" | awk '{print $1}')"
if [[ "$REMOTE_HASH" != "$LOCAL_HASH" ]]; then
  echo "The copied cmux-tui binary failed its SHA-256 check." >&2
  exit 1
fi

echo "Starting the PTY-owning Iroh daemon on $REMOTE_HOST..."
DAEMON_COMMAND="$(cmux_remote_quote_command \
  "$REMOTE_BIN" daemon \
  --session "$SESSION" \
  --socket "$REMOTE_MUX_SOCKET" \
  --state "$REMOTE_MUX_STATE" \
  --iroh \
  --remote-state-dir "$REMOTE_STATE" \
  --remote-link-socket "$REMOTE_LINK_SOCKET" \
  --remote-admin-socket "$REMOTE_ADMIN_SOCKET")"
printf -v REMOTE_DAEMON_PID_FILE_QUOTED '%q' "$REMOTE_DAEMON_PID_FILE"
DAEMON_OWNER_COMMAND="printf '%s\\n' \$\$ > $REMOTE_DAEMON_PID_FILE_QUOTED; exec $DAEMON_COMMAND"
# shellcheck disable=SC2029  # Arguments are escaped above.
ssh -n "${SSH_OPTIONS[@]}" "$REMOTE_HOST" "$DAEMON_OWNER_COMMAND" >"$DAEMON_LOG" 2>&1 &
SSH_DAEMON_PID=$!

ready=0
for _ in $(seq 1 120); do
  if ! kill -0 "$SSH_DAEMON_PID" 2>/dev/null; then
    echo "The remote daemon exited during startup:" >&2
    sed -n '1,220p' "$DAEMON_LOG" >&2
    exit 1
  fi
  if [[ -z "$REMOTE_DAEMON_PID" ]]; then
    read_remote_daemon_pid || true
  elif ! remote_daemon_alive; then
    echo "The remote daemon process exited during startup:" >&2
    sed -n '1,220p' "$DAEMON_LOG" >&2
    exit 1
  fi
  if [[ -n "$REMOTE_DAEMON_PID" ]] \
    && remote_command /bin/test -S "$REMOTE_MUX_SOCKET" >/dev/null 2>&1 \
    && remote_command /bin/test -S "$REMOTE_ADMIN_SOCKET" >/dev/null 2>&1 \
    && remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
      session current ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != "1" ]]; then
  echo "The remote daemon did not become ready:" >&2
  sed -n '1,220p' "$DAEMON_LOG" >&2
  exit 1
fi

if ! CREATED="$(remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
  workspace create --name "$REMOTE_HOST" --json)"; then
  echo "The remote workspace could not be created." >&2
  report_remote_owner_state
  exit 1
fi
if ! TERMINAL_ID="$(printf '%s' "$CREATED" \
  | jq -er '.value.terminal_id // .result.value.terminal_id // .terminal_id')"; then
  echo "The remote workspace response did not include a terminal." >&2
  exit 1
fi
SEED="printf '\\033[2J\\033[H\\033[1;36mRemote PTY on $REMOTE_HOST\\033[0m\\nThe shell and terminal host run on the remote Mac.\\nSwift/AppKit and GhosttyKit render locally over Iroh.\\n\\n\\033[31mred \\033[32mgreen \\033[34mblue \\033[35mmagenta\\033[0m\\nRemote hostname: '; hostname; printf '\\nTry: pwd; uname -a; echo hello from remote\\n\\n'"
if ! remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
  terminal "$TERMINAL_ID" write --text "$SEED" >/dev/null \
  || ! remote_command "$REMOTE_BIN" --socket "$REMOTE_MUX_SOCKET" \
    terminal "$TERMINAL_ID" keys enter >/dev/null; then
  echo "The remote terminal could not be seeded." >&2
  report_remote_owner_state
  exit 1
fi

ADMIN_ERROR="$LOCAL_ROOT/admin-error.log"
if ! INVITATION="$(remote_command "$REMOTE_BIN" enroll create \
  --admin-socket "$REMOTE_ADMIN_SOCKET" --ttl 300 2>"$ADMIN_ERROR")"; then
  report_remote_owner_state
  sed -n '1,80p' "$ADMIN_ERROR" >&2
  exit 1
fi
printf '%s\n' "$INVITATION" >"$INVITATION_FILE"
chmod 600 "$INVITATION_FILE"
INVITATION_ID="$(invitation_id "$INVITATION")"
unset INVITATION

echo "Launching the local Swift/GhosttyKit frontend..."
open -n -W \
  --env "CMUX_NATIVE_INVITATION_FILE=$INVITATION_FILE" \
  --env CMUX_NATIVE_AUTOCONNECT=1 \
  "$RUN_APP_BUNDLE" &
OPEN_PID=$!

for _ in $(seq 1 200); do
  APP_PID="$(find_run_app_pid || true)"
  [[ -n "$APP_PID" ]] && break
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then
    echo "NativeMuxDemo exited before claiming its invitation." >&2
    exit 1
  fi
  sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
  echo "Could not identify the isolated NativeMuxDemo process." >&2
  exit 1
fi

claimed=0
for _ in $(seq 1 120); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "NativeMuxDemo exited before claiming its invitation." >&2
    exit 1
  fi
  PENDING="$(remote_command "$REMOTE_BIN" enroll pending \
    --admin-socket "$REMOTE_ADMIN_SOCKET" --json)"
  if printf '%s' "$PENDING" \
    | jq -e --arg id "$INVITATION_ID" 'any(.[]; .invitation_id == $id)' >/dev/null; then
    claimed=1
    break
  fi
  sleep 0.1
done
if [[ "$claimed" != "1" ]]; then
  echo "NativeMuxDemo did not claim its invitation before the connection timeout." >&2
  exit 1
fi
remote_command "$REMOTE_BIN" enroll approve "$INVITATION_ID" \
  --admin-socket "$REMOTE_ADMIN_SOCKET" >/dev/null

connected=0
for _ in $(seq 1 120); do
  CONNECTED="$(remote_command "$REMOTE_BIN" enroll status \
    --admin-socket "$REMOTE_ADMIN_SOCKET" --json \
    | jq -er '.connected_clients')"
  if (( CONNECTED >= 1 )); then
    connected=1
    break
  fi
  sleep 0.1
done
if [[ "$connected" != "1" ]]; then
  echo "The remote daemon did not observe the Swift client." >&2
  exit 1
fi

echo "Ready. $REMOTE_HOST owns terminal $TERMINAL_ID; this Mac only renders it."
echo "Close the NativeMuxDemo window or quit the app to clean up the remote demo."

while kill -0 "$APP_PID" 2>/dev/null; do
  CONNECTIONS="$(remote_command "$REMOTE_BIN" enroll connections \
    --admin-socket "$REMOTE_ADMIN_SOCKET" --json 2>/dev/null || true)"
  if printf '%s' "$CONNECTIONS" \
    | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SSH_DAEMON_PID" 2>/dev/null; then
    echo "The remote daemon exited while NativeMuxDemo was connected." >&2
    exit 1
  fi
  sleep 0.25
done
