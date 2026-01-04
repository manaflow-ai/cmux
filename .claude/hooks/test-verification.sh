#!/bin/bash
# ============================================================================
# HOOK: test-verification.sh
# EVENT: Stop (3rd in chain)
# PURPOSE: Runs tests for modified files with async fallback for timeouts
# PART OF: Closed-Loop Verification Harness
# DISABLE: TEST_VERIFICATION_DISABLED=1
#
# ARCHITECTURE:
# 1. Check if any async tests from previous run completed
# 2. If async tests failed -> block with error
# 3. Run tests for modified files with timeout
# 4. If timeout -> spawn async background job, allow proceed with warning
# 5. Next stop will check async results
#
# FILES:
# - /tmp/test-async-{session_id}.status  - "running", "passed", "failed"
# - /tmp/test-async-{session_id}.pid     - PID of background job
# - /tmp/test-async-{session_id}.log     - Output of background job
# ============================================================================

set -euo pipefail

# Skip if disabled via env var
if [ "${TEST_VERIFICATION_DISABLED:-}" = "1" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Read session_id from hook stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

# File paths for async tracking
ASYNC_STATUS_FILE="/tmp/test-async-${SESSION_ID}.status"
ASYNC_PID_FILE="/tmp/test-async-${SESSION_ID}.pid"
ASYNC_LOG_FILE="/tmp/test-async-${SESSION_ID}.log"
ATTEMPT_COUNT_FILE="/tmp/test-verification-${SESSION_ID}"

# Timeout for synchronous tests (seconds) - should be less than hook timeout (120s)
SYNC_TIMEOUT=90

# Maximum attempts before giving up on blocking
MAX_ATTEMPTS=5

# ============================================================================
# STEP 1: Check if previous async tests completed (ANY session, not just current)
# ============================================================================
check_all_async_status() {
  local found_issues=false

  # Check ALL async status files (from any session)
  for status_file in /tmp/test-async-*.status; do
    [ -f "$status_file" ] || continue

    local async_session_id
    async_session_id=$(basename "$status_file" .status | sed 's/test-async-//')
    local async_pid_file="/tmp/test-async-${async_session_id}.pid"
    local async_log_file="/tmp/test-async-${async_session_id}.log"

    local status
    status=$(cat "$status_file")

    case "$status" in
      "running")
        # Check if process is still running
        if [ -f "$async_pid_file" ]; then
          local pid
          pid=$(cat "$async_pid_file")
          if kill -0 "$pid" 2>/dev/null; then
            echo "## Async Tests Still Running (session: $async_session_id)" >&2
            echo "" >&2
            echo "Background tests from previous stop are still running (PID: $pid)." >&2
            echo "You can continue working - results will be checked on next stop." >&2
            echo "" >&2
            # Allow proceed, will check again later
          else
            # Process finished but status not updated - check log for results
            if [ -f "$async_log_file" ]; then
              if grep -q "passed\|All.*tests passed" "$async_log_file" 2>/dev/null; then
                echo "passed" > "$status_file"
                echo "## Previous Async Tests Passed (session: $async_session_id)" >&2
                rm -f "$status_file" "$async_pid_file" "$async_log_file"
              else
                echo "failed" > "$status_file"
                found_issues=true
              fi
            fi
          fi
        fi
        ;;
      "passed")
        echo "## Previous Async Tests Passed (session: $async_session_id)" >&2
        echo "" >&2
        rm -f "$status_file" "$async_pid_file" "$async_log_file"
        ;;
      "failed")
        echo "## Previous Async Tests FAILED (session: $async_session_id)" >&2
        echo "" >&2
        echo "Background tests from previous stop have failed." >&2
        echo "" >&2
        if [ -f "$async_log_file" ]; then
          echo "**Test output (last 50 lines):**" >&2
          tail -50 "$async_log_file" >&2
        fi
        echo "" >&2
        echo "**Action required:** Fix failing tests before completing." >&2
        found_issues=true
        ;;
    esac
  done

  if [ "$found_issues" = true ]; then
    # Increment attempt counter
    local attempt_count=0
    if [ -f "$ATTEMPT_COUNT_FILE" ]; then
      attempt_count=$(cat "$ATTEMPT_COUNT_FILE")
    fi
    echo $((attempt_count + 1)) > "$ATTEMPT_COUNT_FILE"
    if [ "$attempt_count" -ge "$MAX_ATTEMPTS" ]; then
      echo "" >&2
      echo "**Warning:** Exceeded $MAX_ATTEMPTS attempts. Allowing proceed but CI may fail." >&2
      # Clean up all async files
      rm -f /tmp/test-async-*.status /tmp/test-async-*.pid /tmp/test-async-*.log "$ATTEMPT_COUNT_FILE"
      return 0
    fi
    return 2  # Block
  fi

  return 0
}

# Run async status check first
if ! check_all_async_status; then
  exit 2
fi

# ============================================================================
# STEP 2: Get modified files that need testing
# ============================================================================
MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null | grep '\.ts$' | grep -v '\.test\.ts$' | grep -v 'node_modules' | grep -v '/dist/' || echo "")

if [ -z "$MODIFIED_FILES" ]; then
  # No modified TS files, check staged files
  MODIFIED_FILES=$(git diff --cached --name-only 2>/dev/null | grep '\.ts$' | grep -v '\.test\.ts$' | grep -v 'node_modules' | grep -v '/dist/' || echo "")
fi

if [ -z "$MODIFIED_FILES" ]; then
  rm -f "$ATTEMPT_COUNT_FILE" "$ASYNC_STATUS_FILE" "$ASYNC_PID_FILE" "$ASYNC_LOG_FILE"
  exit 0  # No files to check
fi

# ============================================================================
# STEP 3: Find corresponding test files
# ============================================================================
MISSING_TESTS=""
EXISTING_TESTS=""

while IFS= read -r file; do
  [ -z "$file" ] && continue

  # Skip files that don't need tests (config, types-only, etc.)
  if echo "$file" | grep -qE '(config|schema|types|index)\.ts$'; then
    continue
  fi

  # Derive expected test file path
  TEST_FILE="${file%.ts}.test.ts"

  if [ -f "$TEST_FILE" ]; then
    EXISTING_TESTS="$EXISTING_TESTS $TEST_FILE"
  else
    # Check if there's a test file in the same directory with different naming
    DIR=$(dirname "$file")
    BASENAME=$(basename "$file" .ts)
    ALT_TEST="$DIR/${BASENAME}.test.ts"

    if [ -f "$ALT_TEST" ]; then
      EXISTING_TESTS="$EXISTING_TESTS $ALT_TEST"
    else
      MISSING_TESTS="$MISSING_TESTS\n- $file (expected: $TEST_FILE)"
    fi
  fi
done <<< "$MODIFIED_FILES"

# Trim whitespace
EXISTING_TESTS=$(echo "$EXISTING_TESTS" | xargs)

# ============================================================================
# STEP 4: Run tests with timeout
# ============================================================================
if [ -n "$EXISTING_TESTS" ]; then
  echo "Running tests for modified files (timeout: ${SYNC_TIMEOUT}s)..." >&2

  # Create temp file for output
  TEST_OUTPUT_FILE=$(mktemp)
  TEST_EXIT=0

  # Run tests with timeout
  if command -v timeout &> /dev/null; then
    # GNU coreutils timeout
    timeout --signal=TERM "${SYNC_TIMEOUT}s" bun test $EXISTING_TESTS > "$TEST_OUTPUT_FILE" 2>&1 || TEST_EXIT=$?
  elif command -v gtimeout &> /dev/null; then
    # macOS with coreutils installed via Homebrew
    gtimeout --signal=TERM "${SYNC_TIMEOUT}s" bun test $EXISTING_TESTS > "$TEST_OUTPUT_FILE" 2>&1 || TEST_EXIT=$?
  else
    # Fallback: use background job with manual timeout
    bun test $EXISTING_TESTS > "$TEST_OUTPUT_FILE" 2>&1 &
    TEST_PID=$!

    # Wait with timeout
    WAITED=0
    while [ $WAITED -lt $SYNC_TIMEOUT ]; do
      if ! kill -0 "$TEST_PID" 2>/dev/null; then
        wait "$TEST_PID" || TEST_EXIT=$?
        break
      fi
      sleep 1
      WAITED=$((WAITED + 1))
    done

    # Check if still running (timeout)
    if kill -0 "$TEST_PID" 2>/dev/null; then
      TEST_EXIT=124  # Same as GNU timeout exit code
      kill -TERM "$TEST_PID" 2>/dev/null || true
      sleep 2
      kill -9 "$TEST_PID" 2>/dev/null || true
    fi
  fi

  TEST_OUTPUT=$(cat "$TEST_OUTPUT_FILE")
  rm -f "$TEST_OUTPUT_FILE"

  # ============================================================================
  # STEP 5: Handle results
  # ============================================================================

  if [ "$TEST_EXIT" -eq 124 ]; then
    # TIMEOUT - spawn async job
    echo "## Tests Timed Out - Running Async" >&2
    echo "" >&2
    echo "Tests for modified files exceeded ${SYNC_TIMEOUT}s timeout." >&2
    echo "Starting background test run - results will be checked on next stop." >&2
    echo "" >&2

    # Spawn full test run in background
    (
      echo "running" > "$ASYNC_STATUS_FILE"
      cd "$CLAUDE_PROJECT_DIR"
      bun test $EXISTING_TESTS > "$ASYNC_LOG_FILE" 2>&1
      if [ $? -eq 0 ]; then
        echo "passed" > "$ASYNC_STATUS_FILE"
      else
        echo "failed" > "$ASYNC_STATUS_FILE"
      fi
    ) &
    ASYNC_PID=$!
    echo "$ASYNC_PID" > "$ASYNC_PID_FILE"
    disown "$ASYNC_PID" 2>/dev/null || true

    echo "Background test PID: $ASYNC_PID" >&2
    echo "Log file: $ASYNC_LOG_FILE" >&2
    echo "" >&2
    echo "**Warning:** Proceeding without test verification. CI may fail if tests fail." >&2

    # Allow proceed but warn
    exit 0

  elif [ "$TEST_EXIT" -ne 0 ]; then
    # FAILED - block
    ATTEMPT_COUNT=0
    if [ -f "$ATTEMPT_COUNT_FILE" ]; then
      ATTEMPT_COUNT=$(cat "$ATTEMPT_COUNT_FILE")
    fi

    if [ "$ATTEMPT_COUNT" -ge "$MAX_ATTEMPTS" ]; then
      echo "## Test Verification - Max Attempts Reached" >&2
      echo "" >&2
      echo "**Warning:** Exceeded $MAX_ATTEMPTS attempts. Allowing proceed but CI may fail." >&2
      rm -f "$ATTEMPT_COUNT_FILE" "$ASYNC_STATUS_FILE" "$ASYNC_PID_FILE" "$ASYNC_LOG_FILE"
      exit 0
    fi

    echo $((ATTEMPT_COUNT + 1)) > "$ATTEMPT_COUNT_FILE"
    echo "## Test Verification Failed (attempt $((ATTEMPT_COUNT + 1))/$MAX_ATTEMPTS)" >&2
    echo "" >&2
    echo "**Tests failed:**" >&2
    echo "$TEST_OUTPUT" | tail -50 >&2
    echo "" >&2
    echo "**Action required:** Fix failing tests before completing." >&2
    exit 2
  fi

  # SUCCESS
  rm -f "$ATTEMPT_COUNT_FILE" "$ASYNC_STATUS_FILE" "$ASYNC_PID_FILE" "$ASYNC_LOG_FILE"
fi

# ============================================================================
# STEP 6: Report missing tests (warning, not blocking)
# ============================================================================
if [ -n "$MISSING_TESTS" ]; then
  echo "## Test Coverage Warning" >&2
  echo "" >&2
  echo "**Modified files without tests:**" >&2
  echo -e "$MISSING_TESTS" >&2
  echo "" >&2
  echo "Per closed-loop verification protocol, consider adding tests for these files." >&2
  echo "Skip this check by setting TEST_VERIFICATION_DISABLED=1" >&2
  echo "" >&2
fi

exit 0
