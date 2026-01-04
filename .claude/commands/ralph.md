---
description: Ralph Wiggum mode - work through beads issues continuously until done
arguments:
  - name: label
    description: Optional label to filter issues (e.g., 'austin')
    required: false
---

# Ralph Wiggum Mode Activated

You are now in **Ralph Wiggum mode** - "I'm helping! I'm helping!"

Your mission: Work through ALL beads issues until there are none left. Keep going and going until everything is done.

**CRITICAL: Every issue MUST go through the closed-loop verification cycle. Never close without verification passing.**

**Action Bias: Do the work. Only ask when you genuinely cannot decide between options.**

## Current Session Setup

```bash
# Get current branch (this is your label)
LABEL=$(git rev-parse --abbrev-ref HEAD)
echo "Working on branch/label: $LABEL"

# Check what's ready to work on
bd ready --label $LABEL
```

## The Ralph Loop (With Verification)

For each iteration:

### 1. Claim the next issue
```bash
bd ready --label {{ label }} --limit 1
bd update <issue-id> --status=in_progress
bd show <issue-id>
```

### 2. Define success criteria FIRST
Before writing ANY code, determine:
- What does "done" look like? (specific outcomes)
- How will you verify it works? (test type)
- What are the failure cases?

### 3. Implement WITH tests
- Write tests alongside implementation, not after
- For functions: create `*.test.ts` adjacent file
- For APIs: create integration tests
- For UI: document manual verification steps

### 4. Run verification loop
```bash
# Run tests for the files you changed
bun test <path/to/file.test.ts>

# Run type check and lint
bun check

# If tests fail: FIX AND RE-RUN
# DO NOT proceed with failing tests
```

### 5. Verify E2E (for user-facing features)
- Start dev server if needed: `./scripts/dev.sh`
- Test the actual user flow
- Document what you verified

### 6. Run review checkpoint (for significant changes)
If this issue involved significant changes (>50 lines, >2 files, new feature):
```bash
/review
```
Address any critical/major issues before closing.

### 7. Commit the work for this issue
```bash
# Stage and commit with issue reference
git add -A
git commit -m "feat: <description>

Closes: <issue-id>"
```

### 8. ONLY NOW close the issue
```bash
# Only after commit + verification passes:
bd close <issue-id>
```

### 9. Continue to next issue
```bash
bd ready --label {{ label }}
# If more issues exist, repeat from step 1
```

## Verification Requirements by Issue Type

| Issue Type | Required Verification |
|------------|----------------------|
| Bug fix | Test that reproduces bug, passes after fix |
| New feature | Unit tests + integration tests + E2E |
| Refactor | Existing tests still pass |
| API endpoint | Integration test with request/response |
| UI component | Manual verification steps documented |

## When You Don't Know How to Verify

If you're unsure how to test something, **poll for clarification**:
- "How should I verify this works? (A) unit test, (B) integration test, (C) manual check"
- "What's the expected behavior when X happens?"

**Never skip verification because you're unsure. Uncertainty is a blocker.**

## Valid vs Invalid Questions

### ❌ INVALID (answer is always YES):
- "Should I complete the integration?" → Just complete it
- "Would you like me to wire up the components?" → Just wire them
- "Should I fix this?" → Just fix it

### ✅ VALID (polls that clarify):
- "Should this return 404 or 400?" → Need to know
- "Is this for all users or admins only?" → Scope question
- "Pattern A or B for this case?" → Technical decision

**If the answer is obviously YES, don't ask. Just do it.**

## Creating New Issues

When creating issues during Ralph mode, ALWAYS use the branch label:
```bash
bd create --title="..." --type=task --priority=2 --labels {{ label }}
```

**Never create issues without the branch label.**

## Important Rules

- **Never close without passing verification**
- **Never stop until `bd ready --label {{ label }}` returns empty** (or context full)
- **Always sync before stopping:** `bd sync`
- **Run `bun check`** after code changes
- **Use TodoWrite** to track multi-step verification within issues

## Context Exhaustion Protocol

If you're running low on context:
1. Complete verification for current issue or pause cleanly
2. Run `bd sync` to save progress
3. Git commit and push any code changes
4. Output a summary: "Ralph session paused at issue X. Verification status: [passed/in-progress]. Run `/ralph {{ label }}` to continue."

## Start Now

```bash
# 1. Check current branch/label
git rev-parse --abbrev-ref HEAD

# 2. See what's ready
bd ready --label {{ label }}

# 3. Pick first issue and start the verification loop
```
