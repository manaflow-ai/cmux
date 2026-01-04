#!/bin/bash
# ============================================================================
# HOOK: multi-agent-review.sh
# EVENT: Stop (4th/last in chain)
# PURPOSE: Runs Codex + Claude review for code quality and protocol compliance
# PART OF: Closed-Loop Verification Harness
# DISABLE: MULTI_AGENT_REVIEW_DISABLED=1
# ============================================================================

set -euo pipefail

# Skip if disabled via env var
if [ "${MULTI_AGENT_REVIEW_DISABLED:-}" = "1" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Read session_id from hook stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")

# Hard stop after 3 reviews to prevent excessive loops (per session)
REVIEW_COUNT_FILE="/tmp/multi-agent-review-${SESSION_ID}"
REVIEW_COUNT=0
if [ -f "$REVIEW_COUNT_FILE" ]; then
  REVIEW_COUNT=$(cat "$REVIEW_COUNT_FILE")
fi
if [ "$REVIEW_COUNT" -ge 3 ]; then
  exit 0  # Hit limit, stop reviewing
fi

# Check if there are any changes to review
DIFF=$(git diff main...HEAD 2>/dev/null || git diff HEAD 2>/dev/null || echo "")
if [ -z "$DIFF" ]; then
  exit 0  # No changes to review
fi

# Create temp files for outputs
CODEX_OUT=$(mktemp)
CLAUDE_OUT=$(mktemp)
trap 'rm -f "$CODEX_OUT" "$CLAUDE_OUT"' EXIT

# Protocol compliance prompt for Claude
PROTOCOL_PROMPT="Review this code change for protocol compliance. Check:
1. Were success/failure criteria defined before implementation?
2. Were multiple architectural approaches considered for significant decisions?
3. Was verification performed (tests written, manual checks documented)?
4. Are there any decisions that should have been escalated for human review?

Output format:
- PASS if protocols were followed
- ISSUES: <list issues> if protocols were not followed

Be strict. If there is no evidence of protocol compliance, flag it.

CODE DIFF:
$DIFF"

# Run reviewers in parallel
{
  # Codex review - code quality, bugs, architecture
  unbuffer codex \
    --dangerously-bypass-approvals-and-sandbox \
    -m gpt-5.2-codex \
    -c model_reasoning_effort="high" \
    review --base main > "$CODEX_OUT" 2>&1 || true
} &
CODEX_PID=$!

{
  # Claude review - protocol compliance
  claude -p "$PROTOCOL_PROMPT" --model sonnet --print > "$CLAUDE_OUT" 2>&1 || true
} &
CLAUDE_PID=$!

# Wait for both
wait $CODEX_PID || true
wait $CLAUDE_PID || true

# Process Codex output
CODEX_CLEAN=$(sed 's/\x1b\[[0-9;]*m//g' "$CODEX_OUT" 2>/dev/null || cat "$CODEX_OUT")
CODEX_FINDINGS=$(echo "$CODEX_CLEAN" | awk '
  /^codex$/ { found=1; content=""; next }
  found { content = content $0 "\n" }
  END { print content }
' | sed '/^$/d' | grep -v '^tokens used' | head -30 || echo "")

# Process Claude output
CLAUDE_FINDINGS=$(cat "$CLAUDE_OUT" | head -50 || echo "")

# Check if either found issues
HAS_ISSUES=0
ISSUES_REPORT=""

# Check Codex findings
if [ -n "$CODEX_FINDINGS" ]; then
  CODEX_VERDICT=$(opencode run "Output: $CODEX_FINDINGS

If the output indicates code review passed with no issues, return exactly 'lgtm'. Otherwise return 'issues'." --model opencode/big-pickle 2>/dev/null || echo "issues")

  if ! echo "$CODEX_VERDICT" | grep -qi "lgtm"; then
    HAS_ISSUES=1
    ISSUES_REPORT="### Codex Findings\n$CODEX_FINDINGS\n\n"
  fi
fi

# Check Claude findings (protocol compliance)
if [ -n "$CLAUDE_FINDINGS" ] && ! echo "$CLAUDE_FINDINGS" | grep -qi "^PASS"; then
  HAS_ISSUES=1
  ISSUES_REPORT="${ISSUES_REPORT}### Protocol Compliance (Claude)\n$CLAUDE_FINDINGS\n\n"
fi

# If no issues, reset counter and exit
if [ "$HAS_ISSUES" -eq 0 ]; then
  rm -f "$REVIEW_COUNT_FILE"
  exit 0
fi

# Has issues - increment counter and report
echo $((REVIEW_COUNT + 1)) > "$REVIEW_COUNT_FILE"

echo "## Multi-Agent Review Findings (review $((REVIEW_COUNT + 1))/3)" >&2
echo "" >&2
echo -e "$ISSUES_REPORT" >&2
echo "---" >&2
echo "**Action required:** Address the findings above before completing this task." >&2
echo "" >&2
echo "Protocol checklist:" >&2
echo "- [ ] Success/failure criteria defined?" >&2
echo "- [ ] Multiple approaches considered (if significant decision)?" >&2
echo "- [ ] Verification performed (tests/manual checks)?" >&2

exit 2
