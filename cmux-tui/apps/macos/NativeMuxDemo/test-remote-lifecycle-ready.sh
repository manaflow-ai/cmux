#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
READY_HELPER="$SCRIPT_DIR/remote-lifecycle-ready.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-ready-test.XXXXXX")"
CHILD_PID=""
WAITER_PID=""
EVENT_FD_OPEN=0
EVENT_READ_FD_OPEN=0
OWNER_EXIT_FD_OPEN=0
RESULT_FD_OPEN=0

cleanup() {
  set +e
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
  if [[ -n "$WAITER_PID" ]] && kill -0 "$WAITER_PID" 2>/dev/null; then
    kill "$WAITER_PID" 2>/dev/null
    wait "$WAITER_PID" 2>/dev/null
  fi
  if [[ "$EVENT_FD_OPEN" == "1" ]]; then
    exec 7<&-
  fi
  if [[ "$EVENT_READ_FD_OPEN" == "1" ]]; then
    exec 8<&-
  fi
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

STALLED_TRANSFER="$TEST_ROOT/stalled-transfer"
mkfifo "$STALLED_TRANSFER"

EVENT_PIPE="$TEST_ROOT/success-events"
mkfifo "$EVENT_PIPE"
(
  printf 'daemon-starting\n' >"$EVENT_PIPE"
  printf 'app-started 12345\n' >"$EVENT_PIPE"
  printf 'ready\n' >"$EVENT_PIPE"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
if ! cmux_wait_for_remote_demo_ready 7 "$CHILD_PID" 2 2; then
  echo "A valid lifecycle event sequence did not become ready." >&2
  exit 1
fi
if [[ "$CMUX_REMOTE_DEMO_APP_PID" != "12345" ]]; then
  echo "The lifecycle waiter did not retain the app owner PID." >&2
  exit 1
fi
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/invalid-events"
mkfifo "$EVENT_PIPE"
(
  printf 'daemon-starting\n' >"$EVENT_PIPE"
  printf 'app-started 12345\n' >"$EVENT_PIPE"
  printf 'app-started 54321\n' >"$EVENT_PIPE"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 7 "$CHILD_PID" 2 2
STATUS=$?
set -e
if [[ "$STATUS" != "22" ]]; then
  echo "A duplicate app owner returned $STATUS instead of protocol status 22." >&2
  exit 1
fi
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/transfer-events"
mkfifo "$EVENT_PIPE"
(
  IFS= read -r _ <"$STALLED_TRANSFER"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 7 "$CHILD_PID" 0.05 2
STATUS=$?
set -e
if [[ "$STATUS" != "20" ]]; then
  echo "A stalled transfer returned $STATUS instead of phase status 20." >&2
  exit 1
fi
exec 7<&-
EVENT_FD_OPEN=0
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/startup-events"
mkfifo "$EVENT_PIPE"
(
  printf 'daemon-starting\n' >"$EVENT_PIPE"
  IFS= read -r _ <"$STALLED_TRANSFER"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 7 "$CHILD_PID" 2 0
STATUS=$?
set -e
if [[ "$STATUS" != "21" ]]; then
  echo "A stalled daemon startup returned $STATUS instead of phase status 21." >&2
  exit 1
fi
exec 7<&-
EVENT_FD_OPEN=0
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

EVENT_PIPE="$TEST_ROOT/exit-events"
mkfifo "$EVENT_PIPE"
(
  printf 'failed 1\n' >"$EVENT_PIPE"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
set +e
cmux_wait_for_remote_demo_ready 7 "$CHILD_PID" 2 2
STATUS=$?
set -e
exec 7<&-
EVENT_FD_OPEN=0
wait "$CHILD_PID"
CHILD_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "An early launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

EVENT_PIPE="$TEST_ROOT/silent-exit-events"
OWNER_EXIT_PIPE="$TEST_ROOT/silent-owner-exit"
RESULT_PIPE="$TEST_ROOT/silent-waiter-result"
mkfifo "$EVENT_PIPE" "$OWNER_EXIT_PIPE" "$RESULT_PIPE"
(
  exec 6>"$EVENT_PIPE"
  printf 'daemon-starting\n' >&6
  exec 6>&-
  printf 'owner-exited\n' >"$OWNER_EXIT_PIPE"
) &
CHILD_PID=$!
exec 7<>"$EVENT_PIPE"
EVENT_FD_OPEN=1
exec 8<"$EVENT_PIPE"
EVENT_READ_FD_OPEN=1
exec 4<>"$OWNER_EXIT_PIPE"
OWNER_EXIT_FD_OPEN=1
exec 9<>"$RESULT_PIPE"
RESULT_FD_OPEN=1
(
  set +e
  cmux_wait_for_remote_demo_ready 8 "$CHILD_PID" 30 30
  printf '%s\n' "$?" >&9
) &
WAITER_PID=$!
exec 7<&-
EVENT_FD_OPEN=0
if ! IFS= read -r -u 4 OWNER_EVENT || [[ "$OWNER_EVENT" != "owner-exited" ]]; then
  echo "The silent launcher did not publish its owner-exit signal." >&2
  exit 1
fi
wait "$CHILD_PID"
CHILD_PID=""
set +e
IFS= read -r -t 3 -u 9 STATUS
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
exec 9<&-
RESULT_FD_OPEN=0
exec 4<&-
OWNER_EXIT_FD_OPEN=0
exec 8<&-
EVENT_READ_FD_OPEN=0
if [[ "$STATUS" != "10" ]]; then
  echo "A silent launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

echo "Remote lifecycle phase budgets passed."
