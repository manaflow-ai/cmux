#!/usr/bin/env bash
# ============================================================================
# HOOK: ralph-sync.sh
# EVENT: SessionEnd
# PURPOSE: Syncs beads progress and validates async tests at session end
# ============================================================================

set -euo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ============================================================================
# STEP 1: Check for pending async test failures
# ============================================================================
check_async_tests() {
  local has_issues=false

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
            echo "⚠️  Async tests still running (session: $session_id)"
            has_issues=true
          else
            # Process finished, check log
            local log_file="/tmp/test-async-${session_id}.log"
            if [ -f "$log_file" ]; then
              if grep -q "passed\|All.*tests passed" "$log_file" 2>/dev/null; then
                echo "passed" > "$status_file"
                echo "✅ Async tests passed (session: $session_id)"
              else
                echo "failed" > "$status_file"
                echo "❌ Async tests FAILED (session: $session_id)"
                has_issues=true
              fi
            fi
          fi
        fi
        ;;
      "failed")
        echo "❌ Async tests FAILED (session: $session_id)"
        has_issues=true
        ;;
      "passed")
        echo "✅ Async tests passed (session: $session_id)"
        rm -f "$status_file" "/tmp/test-async-${session_id}.pid" "/tmp/test-async-${session_id}.log"
        ;;
    esac
  done

  # Check ci-local async status
  if [ -f "/tmp/ci-local-async.status" ]; then
    local status
    status=$(cat "/tmp/ci-local-async.status")

    case "$status" in
      "running")
        echo "⚠️  CI-local checks still running in background"
        has_issues=true
        ;;
      "failed")
        echo "❌ CI-local checks FAILED"
        has_issues=true
        ;;
      "passed")
        echo "✅ CI-local checks passed"
        rm -f "/tmp/ci-local-async.status" "/tmp/ci-local-async.pid" "/tmp/ci-local-async.log"
        ;;
    esac
  fi

  if [ "$has_issues" = true ]; then
    echo ""
    echo "⚠️  WARNING: There are pending/failing async tests."
    echo "   Run 'bun test' to verify before pushing."
    echo ""
  fi
}

check_async_tests

# ============================================================================
# STEP 2: Sync beads to preserve progress
# ============================================================================
if command -v bd &> /dev/null; then
  echo "Syncing beads progress..."
  bd sync 2>/dev/null || true

  # Show remaining work
  REMAINING=$(bd ready --json 2>/dev/null | jq -r 'length' || echo "?")
  echo "Ralph status: $REMAINING issues remaining"
fi
