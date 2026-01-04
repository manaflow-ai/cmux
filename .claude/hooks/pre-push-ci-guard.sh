#!/bin/bash
# ============================================================================
# HOOK: pre-push-ci-guard.sh
# PURPOSE: Final guard before pushing - checks for pending async tests
#
# This hook ensures that any async tests that were started have completed
# successfully before allowing a push. This is the final safety net to
# prevent CI failures.
#
# USAGE: Call from git pre-push hook or manually before pushing
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/../.."

# Check for pending async test results
ASYNC_STATUS_FILE="/tmp/test-async-*.status"
CI_ASYNC_STATUS_FILE="/tmp/ci-local-async.status"

check_async_tests() {
  # Check test-verification async status files
  for status_file in /tmp/test-async-*.status; do
    [ -f "$status_file" ] || continue

    local status
    status=$(cat "$status_file")
    local session_id
    session_id=$(basename "$status_file" .status | sed 's/test-async-//')

    case "$status" in
      "running")
        local pid_file="/tmp/test-async-${session_id}.pid"
        if [ -f "$pid_file" ]; then
          local pid
          pid=$(cat "$pid_file")
          if kill -0 "$pid" 2>/dev/null; then
            echo "⚠️  Async tests still running (session: $session_id, PID: $pid)"
            echo "   Wait for tests to complete or run: kill $pid"
            return 1
          fi
        fi
        # Process finished, check log
        local log_file="/tmp/test-async-${session_id}.log"
        if [ -f "$log_file" ]; then
          if ! grep -q "passed\|All.*tests passed" "$log_file" 2>/dev/null; then
            echo "❌ Async tests FAILED (session: $session_id)"
            echo "   Log: $log_file"
            tail -20 "$log_file"
            return 1
          fi
        fi
        ;;
      "failed")
        echo "❌ Async tests FAILED (session: $session_id)"
        local log_file="/tmp/test-async-${session_id}.log"
        if [ -f "$log_file" ]; then
          tail -20 "$log_file"
        fi
        return 1
        ;;
    esac
  done

  # Check ci-local async status
  if [ -f "$CI_ASYNC_STATUS_FILE" ]; then
    local status
    status=$(cat "$CI_ASYNC_STATUS_FILE")

    case "$status" in
      "running")
        if [ -f "/tmp/ci-local-async.pid" ]; then
          local pid
          pid=$(cat "/tmp/ci-local-async.pid")
          if kill -0 "$pid" 2>/dev/null; then
            echo "⚠️  CI-local checks still running (PID: $pid)"
            echo "   Wait for checks or run: ./scripts/ci-local.sh --check-async"
            return 1
          fi
        fi
        ;;
      "failed")
        echo "❌ CI-local checks FAILED"
        if [ -f "/tmp/ci-local-async.log" ]; then
          tail -20 "/tmp/ci-local-async.log"
        fi
        return 1
        ;;
    esac
  fi

  return 0
}

if ! check_async_tests; then
  echo ""
  echo "=========================================="
  echo "🚫 Push blocked: Async tests have issues"
  echo "=========================================="
  echo ""
  echo "Fix the failing tests before pushing."
  echo "Or bypass with: git push --no-verify (not recommended)"
  exit 1
fi

echo "✅ No pending async test failures"
exit 0
