#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
READY_HELPER="$SCRIPT_DIR/remote-lifecycle-ready.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-ready-test.XXXXXX")"
FIXTURE="$TEST_ROOT/lifecycle-fixture.sh"
SUPERVISOR_PID=""
WAITER_PID=""
EVENT_READ_FD_OPEN=0
OWNER_EXIT_FD_OPEN=0
RESULT_FD_OPEN=0

cleanup_supervisor() {
  set +e
  if [[ -n "$SUPERVISOR_PID" ]]; then
    kill "$SUPERVISOR_PID" 2>/dev/null
    wait "$SUPERVISOR_PID" 2>/dev/null
    SUPERVISOR_PID=""
  fi
}

close_event_channel() {
  if [[ "$EVENT_READ_FD_OPEN" == "1" ]]; then
    exec 8<&-
    EVENT_READ_FD_OPEN=0
  fi
}

cleanup() {
  set +e
  cleanup_supervisor
  if [[ -n "$WAITER_PID" ]]; then
    kill "$WAITER_PID" 2>/dev/null
    wait "$WAITER_PID" 2>/dev/null
  fi
  close_event_channel
  if [[ "$OWNER_EXIT_FD_OPEN" == "1" ]]; then
    exec 4<&-
  fi
  if [[ "$RESULT_FD_OPEN" == "1" ]]; then
    exec 9<&-
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$READY_HELPER" ]]; then
  echo "Missing phase-aware remote lifecycle waiter: $READY_HELPER" >&2
  exit 1
fi

# shellcheck source=remote-lifecycle-ready.sh
source "$READY_HELPER"

cat >"$FIXTURE" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail

mode="$1"
stall_pipe="$2"
cleanup_marker="$3"
owner_exit_pipe="$4"

publish() {
  /usr/bin/perl -MFcntl=O_WRONLY,O_NONBLOCK -e '
    my ($path, $event) = @ARGV;
    sysopen(my $channel, $path, O_WRONLY | O_NONBLOCK) or exit 1;
    print {$channel} "$event\n" or exit 1;
  ' "$CMUX_NATIVE_LIFECYCLE_PIPE" "$1"
}

stall() {
  IFS= read -r _ <"$stall_pipe"
}

case "$mode" in
  success)
    publish daemon-starting
    publish "app-started 12345"
    publish ready
    ;;
  duplicate-owner)
    publish daemon-starting
    publish "app-started 12345"
    publish "app-started 54321"
    stall
    ;;
  stalled-transfer)
    stall
    ;;
  stalled-startup)
    publish daemon-starting
    stall
    ;;
  early-failure)
    publish "failed 1"
    exit 1
    ;;
  cleanup-order)
    cleanup_fixture() {
      : >"$cleanup_marker"
      publish "failed 143"
      exit 143
    }
    trap cleanup_fixture TERM
    publish daemon-starting
    publish "app-started 12345"
    publish ready
    stall
    ;;
  silent-owner-exit)
    printf 'owner-exited\n' >"$owner_exit_pipe"
    exit 10
    ;;
  *) exit 2 ;;
esac
FIXTURE
chmod 700 "$FIXTURE"

STALL_PIPE="$TEST_ROOT/stall"
CLEANUP_MARKER="$TEST_ROOT/cleanup-complete"
OWNER_EXIT_PIPE="$TEST_ROOT/owner-exit"
mkfifo "$STALL_PIPE" "$OWNER_EXIT_PIPE"

start_fixture() {
  local name="$1"
  local mode="$2"
  local transfer_timeout="$3"
  local startup_timeout="$4"
  local exit_timeout="$5"
  EVENT_PIPE="$TEST_ROOT/$name-events"
  PROGRESS_PIPE="$TEST_ROOT/$name-progress"
  mkfifo "$EVENT_PIPE" "$PROGRESS_PIPE"
  (
    exec 6>"$EVENT_PIPE"
    cmux_supervise_remote_demo \
      6 "$PROGRESS_PIPE" \
      "$transfer_timeout" "$startup_timeout" "$exit_timeout" \
      -- env CMUX_NATIVE_LIFECYCLE_PIPE="$PROGRESS_PIPE" \
      "$FIXTURE" "$mode" "$STALL_PIPE" "$CLEANUP_MARKER" "$OWNER_EXIT_PIPE"
  ) &
  SUPERVISOR_PID=$!
  exec 8<"$EVENT_PIPE"
  EVENT_READ_FD_OPEN=1
}

finish_supervisor() {
  local expected_status="$1"
  local status
  set +e
  wait "$SUPERVISOR_PID"
  status=$?
  set -e
  SUPERVISOR_PID=""
  if [[ "$status" != "$expected_status" ]]; then
    echo "The lifecycle supervisor exited with $status instead of $expected_status." >&2
    exit 1
  fi
}

start_fixture success success 2 2 2
if ! cmux_wait_for_remote_demo_ready 8; then
  echo "A valid lifecycle event sequence did not become ready." >&2
  exit 1
fi
if [[ "$CMUX_REMOTE_DEMO_APP_PID" != "12345" ]]; then
  echo "The lifecycle waiter did not retain the app owner PID." >&2
  exit 1
fi
if ! cmux_wait_for_remote_demo_exit 8; then
  echo "The lifecycle waiter did not observe launcher completion." >&2
  exit 1
fi
if [[ "$CMUX_REMOTE_DEMO_LAUNCHER_STATUS" != "0" ]]; then
  echo "The lifecycle waiter lost the launcher exit status." >&2
  exit 1
fi
finish_supervisor 0
close_event_channel

start_fixture duplicate duplicate-owner 2 2 2
set +e
cmux_wait_for_remote_demo_ready 8
STATUS=$?
set -e
if [[ "$STATUS" != "22" ]]; then
  echo "A duplicate app owner returned $STATUS instead of protocol status 22." >&2
  exit 1
fi
cleanup_supervisor
close_event_channel

start_fixture transfer stalled-transfer 1 2 2
set +e
cmux_wait_for_remote_demo_ready 8
STATUS=$?
set -e
if [[ "$STATUS" != "20" ]]; then
  echo "A stalled transfer returned $STATUS instead of phase status 20." >&2
  exit 1
fi
cleanup_supervisor
close_event_channel

start_fixture startup stalled-startup 2 0 2
set +e
cmux_wait_for_remote_demo_ready 8
STATUS=$?
set -e
if [[ "$STATUS" != "21" ]]; then
  echo "A stalled daemon startup returned $STATUS instead of phase status 21." >&2
  exit 1
fi
cleanup_supervisor
close_event_channel

start_fixture failure early-failure 2 2 2
set +e
cmux_wait_for_remote_demo_ready 8
STATUS=$?
set -e
if [[ "$STATUS" != "10" ]]; then
  echo "An early launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi
if ! cmux_wait_for_remote_demo_exit 8; then
  echo "The lifecycle waiter did not observe the failed launcher completion." >&2
  exit 1
fi
finish_supervisor 1
close_event_channel

start_fixture cleanup cleanup-order 2 2 2
if ! cmux_wait_for_remote_demo_ready 8; then
  echo "The cleanup-order fixture did not become ready." >&2
  exit 1
fi
cmux_request_remote_demo_exit "$SUPERVISOR_PID"
kill "$SUPERVISOR_PID"
if ! cmux_wait_for_remote_demo_exit 8; then
  echo "The cleanup-order fixture did not publish launcher completion." >&2
  exit 1
fi
if [[ ! -f "$CLEANUP_MARKER" ]]; then
  echo "The supervisor published launcher completion before cleanup finished." >&2
  exit 1
fi
if [[ "$CMUX_REMOTE_DEMO_LAUNCHER_STATUS" != "143" ]]; then
  echo "The cleanup-order fixture lost its exit status." >&2
  exit 1
fi
finish_supervisor 143
close_event_channel

RESULT_PIPE="$TEST_ROOT/silent-waiter-result"
mkfifo "$RESULT_PIPE"
exec 4<>"$OWNER_EXIT_PIPE"
OWNER_EXIT_FD_OPEN=1
exec 9<>"$RESULT_PIPE"
RESULT_FD_OPEN=1
start_fixture silent silent-owner-exit 30 30 3
(
  set +e
  cmux_wait_for_remote_demo_ready 8
  printf '%s %s\n' "$?" "$CMUX_REMOTE_DEMO_LAUNCHER_STATUS" >&9
) &
WAITER_PID=$!
if ! IFS= read -r -u 4 OWNER_EVENT || [[ "$OWNER_EVENT" != "owner-exited" ]]; then
  echo "The silent launcher did not publish its owner-exit signal." >&2
  exit 1
fi
set +e
IFS=' ' read -r -t 3 -u 9 STATUS PUBLISHED_LAUNCHER_STATUS
RESULT_STATUS=$?
set -e
if [[ "$RESULT_STATUS" != "0" ]]; then
  kill "$WAITER_PID" 2>/dev/null || true
  wait "$WAITER_PID" 2>/dev/null || true
  WAITER_PID=""
  echo "A silent launcher exit did not release the lifecycle waiter before its final deadline." >&2
  exit 1
fi
wait "$WAITER_PID"
WAITER_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "A silent launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi
if [[ "$PUBLISHED_LAUNCHER_STATUS" != "10" ]]; then
  echo "The silent launcher did not publish its explicit terminal status." >&2
  exit 1
fi
finish_supervisor 10
close_event_channel

echo "Remote lifecycle supervisor protocol passed."
