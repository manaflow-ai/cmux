---
description: Run multi-agent code review checkpoint (Codex + Claude)
---

# Multi-Agent Code Review Checkpoint

**Run this proactively during implementation, not just at the end.**

## When to Run This

Run `/review` when:
- You've made significant changes (>50 lines, >2 files)
- You're unsure if an approach is correct
- Before moving to the next beads issue
- After implementing a new feature or fixing a complex bug

## Review Process

```bash
cd "$CLAUDE_PROJECT_DIR"

echo "## Running Multi-Agent Review..."
echo ""

# Temp files
CODEX_OUT=$(mktemp)
CLAUDE_OUT=$(mktemp)
trap 'rm -f "$CODEX_OUT" "$CLAUDE_OUT"' EXIT

# Get diff for Claude
DIFF=$(git diff main...HEAD 2>/dev/null || git diff HEAD 2>/dev/null || echo "No changes")

# Run Codex review
echo "### Codex Code Quality Review"
unbuffer codex \
  --dangerously-bypass-approvals-and-sandbox \
  -m gpt-5.2-codex \
  -c model_reasoning_effort="high" \
  review --base main 2>&1 | tee "$CODEX_OUT" || true

echo ""
echo "---"
echo ""

# Run Claude protocol compliance review
echo "### Claude Protocol Compliance Check"
PROTOCOL_PROMPT="Review this code change for protocol compliance:
1. Were success/failure criteria defined before implementation?
2. Were multiple architectural approaches considered for significant decisions?
3. Was verification performed (tests written, manual checks)?
4. Any decisions that should have been escalated for human review?

Be specific about what was missing or could be improved.

CODE DIFF:
$DIFF"

claude -p "$PROTOCOL_PROMPT" --model sonnet --print 2>&1 | tee "$CLAUDE_OUT" || true

echo ""
echo "---"
echo ""
echo "## Summary"
echo "Review complete. Address issues and continue working."
```

## After Review - ACTION (not asking permission)

1. **CRITICAL issues** - Fix immediately
2. **MAJOR issues** - Fix now or create beads issue
3. **MINOR issues** - Create beads issue for later:
   ```bash
   bd create --title="Address review feedback: ..." --type=task --priority=2 --labels $(git rev-parse --abbrev-ref HEAD)
   ```

4. **Continue working** - The review is a checkpoint, not a stopping point

## After Fixing Issues

```bash
# Check remaining beads work
bd ready --label $(git rev-parse --abbrev-ref HEAD)
```

Then pick up the next issue and keep going.
