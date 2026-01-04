#!/bin/bash
# ============================================================================
# HOOK: continue-check.sh
# EVENT: Stop (1st in chain)
# PURPOSE: Detects incomplete beads issues, directs Claude to continue working
# PART OF: Closed-Loop Verification Harness
# DISABLE: CONTINUE_CHECK_DISABLED=1
# ============================================================================

set -euo pipefail

# Skip if disabled via env var
if [ "${CONTINUE_CHECK_DISABLED:-}" = "1" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Read session_id from hook stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

# Limit reminders per session to prevent infinite loops (max 5)
REMINDER_COUNT_FILE="/tmp/continue-check-${SESSION_ID}"
REMINDER_COUNT=0
if [ -f "$REMINDER_COUNT_FILE" ]; then
  REMINDER_COUNT=$(cat "$REMINDER_COUNT_FILE")
fi
if [ "$REMINDER_COUNT" -ge 5 ]; then
  exit 0  # Hit limit, stop reminding
fi

# Get current branch (this is the label filter)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Check for in-progress issues with branch label
if [ -n "$BRANCH" ]; then
  IN_PROGRESS=$(bd list --status=in_progress --label "$BRANCH" --json 2>/dev/null || echo "[]")
  READY=$(bd ready --label "$BRANCH" --json 2>/dev/null || echo "[]")
else
  IN_PROGRESS=$(bd list --status=in_progress --json 2>/dev/null || echo "[]")
  READY=$(bd ready --json 2>/dev/null || echo "[]")
fi

IN_PROGRESS_COUNT=$(echo "$IN_PROGRESS" | jq 'length' 2>/dev/null || echo "0")
READY_COUNT=$(echo "$READY" | jq 'length' 2>/dev/null || echo "0")

# If no incomplete work for this branch, exit silently
if [ "$IN_PROGRESS_COUNT" -eq 0 ] && [ "$READY_COUNT" -eq 0 ]; then
  rm -f "$REMINDER_COUNT_FILE"
  exit 0
fi

# Has incomplete work - increment counter
echo $((REMINDER_COUNT + 1)) > "$REMINDER_COUNT_FILE"

# Get the next issue to work on
NEXT_ISSUE=""
NEXT_TITLE=""
if [ "$IN_PROGRESS_COUNT" -gt 0 ]; then
  NEXT_ISSUE=$(echo "$IN_PROGRESS" | jq -r '.[0].id' 2>/dev/null || echo "")
  NEXT_TITLE=$(echo "$IN_PROGRESS" | jq -r '.[0].title' 2>/dev/null || echo "")
elif [ "$READY_COUNT" -gt 0 ]; then
  NEXT_ISSUE=$(echo "$READY" | jq -r '.[0].id' 2>/dev/null || echo "")
  NEXT_TITLE=$(echo "$READY" | jq -r '.[0].title' 2>/dev/null || echo "")
fi

# Output directive (not a question) to continue working
echo "## CONTINUE WORKING - Incomplete Issues for branch '$BRANCH'" >&2
echo "" >&2
echo "**DO NOT STOP. DO NOT ASK. CONTINUE WORKING.**" >&2
echo "" >&2

if [ -n "$NEXT_ISSUE" ]; then
  echo "**Next issue:** $NEXT_ISSUE - $NEXT_TITLE" >&2
  echo "" >&2
  echo "**Commands to run:**" >&2
  echo "\`\`\`bash" >&2
  if [ "$IN_PROGRESS_COUNT" -eq 0 ]; then
    echo "bd update $NEXT_ISSUE --status=in_progress" >&2
  fi
  echo "bd show $NEXT_ISSUE" >&2
  echo "\`\`\`" >&2
  echo "" >&2
fi

echo "**Remaining work (label=$BRANCH):**" >&2
echo "- In-progress: $IN_PROGRESS_COUNT" >&2
echo "- Ready: $READY_COUNT" >&2
echo "" >&2

if [ "$IN_PROGRESS_COUNT" -gt 0 ]; then
  echo "**In-progress issues:**" >&2
  echo "$IN_PROGRESS" | jq -r '.[] | "- \(.id): \(.title)"' 2>/dev/null >&2 || true
  echo "" >&2
fi

if [ "$READY_COUNT" -gt 0 ]; then
  echo "**Ready issues:**" >&2
  echo "$READY" | jq -r '.[] | "- \(.id): \(.title)"' 2>/dev/null | head -5 >&2 || true
  if [ "$READY_COUNT" -gt 5 ]; then
    echo "  ... and $((READY_COUNT - 5)) more" >&2
  fi
  echo "" >&2
fi

echo "**INSTRUCTION: Continue working on these issues. Do not ask permission. Do not stop until all issues with label='$BRANCH' are closed.**" >&2

exit 2
