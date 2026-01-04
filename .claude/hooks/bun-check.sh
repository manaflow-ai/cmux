#!/bin/bash
# ============================================================================
# HOOK: bun-check.sh
# EVENT: Stop (2nd in chain)
# PURPOSE: Runs `bun check` for TypeScript type errors and linting
# DISABLE: BUN_CHECK_DISABLED=1
# ============================================================================

set -euo pipefail

# Skip if disabled via env var
if [ "${BUN_CHECK_DISABLED:-}" = "1" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Read session_id from hook stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

# Hard stop after 5 failures to prevent excessive loops (per session)
FAIL_COUNT_FILE="/tmp/bun-check-fails-${SESSION_ID}"
FAIL_COUNT=0
if [ -f "$FAIL_COUNT_FILE" ]; then
  FAIL_COUNT=$(cat "$FAIL_COUNT_FILE")
fi
if [ "$FAIL_COUNT" -ge 5 ]; then
  exit 0  # Hit limit, stop showing issues
fi

# Run bun check
OUTPUT=$(bun check 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

# If bun check passed (exit 0), reset counter and exit silently
if [ "$EXIT_CODE" -eq 0 ]; then
  rm -f "$FAIL_COUNT_FILE"
  exit 0
fi

# Has errors - increment counter and show to Claude
echo $((FAIL_COUNT + 1)) > "$FAIL_COUNT_FILE"
echo "## bun check failed (attempt $((FAIL_COUNT + 1))/5)" >&2
echo "" >&2
echo "$OUTPUT" >&2
exit 2
