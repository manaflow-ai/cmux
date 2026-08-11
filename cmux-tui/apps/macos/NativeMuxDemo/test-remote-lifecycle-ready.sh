#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
READY_HELPER="$SCRIPT_DIR/remote-lifecycle-ready.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-ready-test.XXXXXX")"
CHILD_PID=""

cleanup() {
  set +e
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
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

LOG="$TEST_ROOT/launcher.log"
POLL_REQUEST="$TEST_ROOT/poll-request"
POLL_RELEASE="$TEST_ROOT/poll-release"
STALLED_TRANSFER="$TEST_ROOT/stalled-transfer"
mkfifo "$POLL_REQUEST" "$POLL_RELEASE" "$STALLED_TRANSFER"

await_poll() {
  IFS= read -r _ <"$POLL_REQUEST"
}

release_poll() {
  printf 'continue\n' >"$POLL_RELEASE"
}

# Drive the helper by its poll boundary so this test does not use wall time.
# shellcheck disable=SC2329 # Called by the sourced readiness helper.
sleep() {
  local poll_seconds="$1"
  printf '%s\n' "$poll_seconds" >"$POLL_REQUEST"
  IFS= read -r _ <"$POLL_RELEASE"
}

: >"$LOG"
(
  for _ in 1 2 3 4 5; do
    await_poll
    release_poll
  done
  await_poll
  echo "Starting the PTY-owning Iroh daemon on test-host..."
  release_poll
  await_poll
  release_poll
  await_poll
  echo "Ready. Remote PTY is on test-host."
  release_poll
) >>"$LOG" &
CHILD_PID=$!
if ! cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 20 5 0.01; then
  echo "A valid long transfer consumed the shorter daemon-startup budget." >&2
  exit 1
fi
wait "$CHILD_PID"
CHILD_PID=""
unset -f sleep

: >"$LOG"
# A reader blocked on an owner-controlled FIFO stays alive until the test kills
# it. This models a stalled transfer without depending on elapsed time.
IFS= read -r _ <"$STALLED_TRANSFER" &
CHILD_PID=$!
set +e
cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 3 2 0.01
STATUS=$?
set -e
if [[ "$STATUS" != "20" ]]; then
  echo "A stalled transfer returned $STATUS instead of phase status 20." >&2
  exit 1
fi
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

echo "Starting the PTY-owning Iroh daemon on test-host..." >"$LOG"
sleep 1 &
CHILD_PID=$!
set +e
cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 10 3 0.01
STATUS=$?
set -e
if [[ "$STATUS" != "21" ]]; then
  echo "A stalled daemon startup returned $STATUS instead of phase status 21." >&2
  exit 1
fi
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""

: >"$LOG"
true &
CHILD_PID=$!
wait "$CHILD_PID"
set +e
cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 10 10 0.01
STATUS=$?
set -e
CHILD_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "An early launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

echo "Remote lifecycle phase budgets passed."
