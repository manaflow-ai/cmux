#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
READY_HELPER="$SCRIPT_DIR/remote-lifecycle-ready.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-ready-test.XXXXXX")"
CHILD_PID=""
EVENT_FD_OPEN=0
EVENT_READ_FD_OPEN=0

cleanup() {
  set +e
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  if [[ "$EVENT_FD_OPEN" == "1" ]]; then
    exec 7<&-
  fi
  if [[ "$EVENT_READ_FD_OPEN" == "1" ]]; then
    exec 8<&-
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

STALLED_TRANSFER="$TEST_ROOT/stalled-transfer"
mkfifo "$STALLED_TRANSFER"

EVENT_PIPE="$TEST_ROOT/success-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
  printf 'daemon-starting\n' >&6
  printf 'app-started 12345\n' >&6
  printf 'ready\n' >&6
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
if ! cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 2 2; then
  echo "A valid lifecycle event sequence did not become ready." >&2
  exit 1
fi
if [[ "$CMUX_REMOTE_DEMO_APP_PID" != "12345" ]]; then
  echo "The lifecycle waiter did not retain the app owner PID." >&2
  exit 1
fi
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/invalid-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
  printf 'daemon-starting\n' >&6
  printf 'app-started 12345\n' >&6
  printf 'app-started 54321\n' >&6
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 2 2
STATUS=$?
set -e
if [[ "$STATUS" != "22" ]]; then
  echo "A duplicate app owner returned $STATUS instead of protocol status 22." >&2
  exit 1
fi
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/transfer-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
  IFS= read -r _ <"$STALLED_TRANSFER"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 1 2
STATUS=$?
set -e
if [[ "$STATUS" != "20" ]]; then
  echo "A stalled transfer returned $STATUS instead of phase status 20." >&2
  exit 1
fi
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/startup-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
  printf 'daemon-starting\n' >&6
  IFS= read -r _ <"$STALLED_TRANSFER"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 2 0
STATUS=$?
set -e
if [[ "$STATUS" != "21" ]]; then
  echo "A stalled daemon startup returned $STATUS instead of phase status 21." >&2
  exit 1
fi
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/exit-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
  printf 'failed 1\n' >&6
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 2 2
STATUS=$?
set -e
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "An early launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

EVENT_PIPE="$TEST_ROOT/silent-exit-events"
mkfifo "$EVENT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'launcher-started\n' >&6
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 2 2
STATUS=$?
set -e
exec 8<&-
EVENT_READ_FD_OPEN=0
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "A silent launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

echo "Remote lifecycle phase budgets passed."
