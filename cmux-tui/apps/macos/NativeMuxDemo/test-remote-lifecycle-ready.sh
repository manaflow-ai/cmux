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
: >"$LOG"
(
  sleep 0.06
  echo "Starting the PTY-owning Iroh daemon on test-host..."
  sleep 0.02
  echo "Ready. Remote PTY is on test-host."
  sleep 0.05
) >>"$LOG" &
CHILD_PID=$!
if ! cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 20 5 0.01; then
  echo "A valid long transfer consumed the shorter daemon-startup budget." >&2
  exit 1
fi
wait "$CHILD_PID"
CHILD_PID=""

: >"$LOG"
sleep 1 &
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
sleep 0.01 &
CHILD_PID=$!
sleep 0.03
set +e
cmux_wait_for_remote_demo_ready "$LOG" "$CHILD_PID" 10 10 0.01
STATUS=$?
set -e
wait "$CHILD_PID" 2>/dev/null || true
CHILD_PID=""
if [[ "$STATUS" != "10" ]]; then
  echo "An early launcher exit returned $STATUS instead of status 10." >&2
  exit 1
fi

echo "Remote lifecycle phase budgets passed."
