This project is called cmux. cmux is a web app that spawns Claude Code, Codex CLI, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel across multiple tasks. For each run, cmux spawns an isolated openvscode instance via Docker or a configurable sandbox provider. The openvscode instance by default opens the git diff UI and a terminal with the running dev server (configurable via devcontainer.json).

# Config

Use bun to install dependencies and run the project.
`./scripts/dev.sh` will start the project. Optional flags:

- `--force-docker-build`: Rebuild worker image even if cached.

If you make code changes, run `bun check` and fix errors after completing a task.

# Backend

This project uses Convex and Hono.
Hono is defined in apps/www/lib/hono-app.ts as well as apps/www/lib/routes/\*
The Hono app generates a client in @cmux/www-openapi-client. This is automatically re-generated when the dev-server is running. If you change the Hono app (and the dev server isn't running), you should run `(cd apps/www && bun run generate-openapi-client)` to re-generate the client. Note that the generator is in www and not www-openapi-client.
We MUST force validation of requests that do not have the proper `Content-Type`. Set the value of `request.body.required` to `true`. For example:

```ts
app.openapi(
  createRoute({
    method: "post",
    path: "/books",
    request: {
      body: {
        content: {
          "application/json": {
            schema: z.object({
              title: z.string(),
            }),
          },
        },
        required: true, // <== add
      },
    },
    responses: {
      200: {
        description: "Success message",
      },
    },
  }),
  (c) => c.json(c.req.valid("json"))
);
```

## Convex

Schemas are defined in packages/convex/convex/schema.ts.
If you're working in Convex dir, you cannot use node APIs/import from "node:\*"
Use crypto.subtle instead of node:crypto
Exception is if the file defines only actions and includes a "use node" directive at the top of the file
To query Convex data during development, first cd into packages/convex, and run `bunx convex data <table> --format jsonl | rg "pattern"` (e.g., `bunx convex data sessions --format jsonl | rg "mn7abc123"`).

## Sandboxes

This project uses Morph sandboxes for running Claude Code/Codex/other coding CLIs inside.
To inspect Morph instances, use the morphcloud cli with the corresponding morphvm\_ id:

```bash
uvx --env-file .env morphcloud instance exec morphvm_q11mhv3p "ls"
🏁  Command execution complete!
--- Stdout ---
server.log
xagi-server
--- Exit Code: 0 ---
```

Morph snapshots capture RAM state. So after snapshot, running processes will still be running.
To modify and rebuild all snapshots, edit `./scripts/snapshot.py` and run `uv run --env-file .env ./scripts/snapshot.py`
After building a snapshot, you should always use the `say` command to notify the user to verify the changes that were made to the snapshot.
After the say command, you should give the user a table with the snapshot preset and vnc/vscode/xterm urls.
.env sometimes might not exist, but you can still run the script if `echo $MORPH_API_KEY` works.

# Frontend

This project uses React, TanStack Router, TanStack Query, Shadcn UI, and Tailwind CSS.
Always use tailwind `neutral` instead of `gray` for gray colors.
Always support both light and dark mode.

# Misc

Always use "node:" prefixes for node imports
Do not use the "any" type
Do not use casts unless absolutely necessary. Most casts may be solved with zod parsing.
Don't modify README.md unless explicitly asked
Do not write docs unless explicitly asked
Do not use dynamic imports unless absolutely necessary. Exceptions include when you're following existing patterns in the codebase
We're using Node 24, which supports global fetch
When using try/catch, never suppress errors. Always console.error any errors.

# Tests

Use vitest
Place test files next to the file they test using a .test.ts extension
Do not use mocks
Do not do early returns (eg. skipping tests if we're missing environment variables)
Make tests resilient

## Logs

When running `./scripts/dev.sh`, service logs are written to `logs/{type}.log`:

- docker-compose.log: Output from `.devcontainer` Docker Compose stack. Hidden from console by default; use `--show-compose-logs` to stream.
- convex-dev.log: Convex development server (`bunx convex dev`).
- server.log: Backend dev server in `apps/server`.
- client.log: Frontend dev server in `apps/client` (Vite).

Log files are overwritten on each run. Use `tail -f logs/<file>` to follow live output.

## cmux/dmux cli

The cmux cli is written in Rust.
If working on the cmux cli (dmux in development mode), first read packages/sandbox/AGENTS.md

## Action Bias with Clarifying Questions

**Do the work. Only ask when you genuinely cannot decide.**

### ❌ DON'T ASK (answer is always YES):
```
"Would you like me to..."         → Just do it.
"Should I fix this bug?"          → Just fix it.
"Do you want me to continue?"     → Keep going.
"Should I complete the integration?" → Complete it.
```

### ✅ DO ASK (when you can't decide the right approach):
```
"The API could return 404 or 400 for this case. Which is correct?"
"Should this data be persisted or kept in memory?"
"Is this feature for all users or just admins?"
"Pattern A or B? Here are the trade-offs: [list them]"
"I'm unsure how to handle X. Options are: [A] ... [B] ..."
```

### ✅ When to Surface Decisions to User

**Ask when there's genuine ambiguity you cannot resolve:**
- Multiple valid implementation approaches with real trade-offs
- Business logic that affects user experience
- Architectural decisions that affect future work
- You're uncertain and the wrong choice would be costly
- Breaking changes or backward compatibility concerns

**Present options clearly:**
```
## Implementation Decision: [Topic]

**Option A:** [approach]
- Pros: ...
- Cons: ...

**Option B:** [approach]
- Pros: ...
- Cons: ...

**My lean:** Option A because [reasoning], but this affects [X] so wanted to check.
```

### The Core Rule

**If you CAN decide confidently → just do it.**
**If you genuinely CANNOT decide → surface the options.**

- Found a bug? Fix it.
- Tests failing? Fix them.
- Components not wired? Wire them.
- Uncertain between two valid patterns? Ask with trade-offs.
- Don't know the business requirement? Ask.

### Discovered Work Protocol

**Before creating ANY issue, ask yourself:**
1. Is this necessary to complete the current task?
2. Is this in scope for what the user asked?

**If NO to either → DO NOT create the issue.**

❌ **OUT OF SCOPE (don't create issues for):**
- "Nice to have" improvements
- Future features not requested
- Refactoring unrelated code
- Supporting additional platforms/providers
- Product roadmap items

✅ **IN SCOPE (do create issues for):**
- Blocking bugs found during implementation
- Missing pieces required to complete current task
- Tests needed for code you're writing
- Direct dependencies of the requested work

**When you find in-scope work:**

1. **Verify it's necessary** - Can you complete the user's request without this?
2. **Create issue only if blocking:**
   ```bash
   bd create --title="Wire RunVideoGallery to diff view" --type=task --priority=1 --labels $(git rev-parse --abbrev-ref HEAD)
   ```
3. **Keep working** - don't stop to ask permission

**Only stop when:**
- Current task is complete
- All tests pass
- You need a decision you cannot make yourself

## Task Planning with Beads

**Use beads as the primary task tracker, NOT TodoWrite.**

### Default Workflow (ALWAYS follow this)

Before starting any non-trivial task:

1. **Ask clarifying questions FIRST** - but ONLY if they are:
   - Genuinely ambiguous (multiple valid interpretations)
   - Missing critical context that affects implementation
   - About scope boundaries that could lead to wasted work

   **DO NOT ask questions that are:**
   - Obvious from context or the codebase
   - Answerable by reading existing code
   - About preferences when there's a clear best practice
   - Filler questions to seem thorough

2. **Create beads issues** - Break work into trackable issues
3. **Execute systematically** - Work through issues one by one

### Quick reference
- `bd ready` - See available work
- `bd create --title="..." --type=task --priority=2 --labels <branch>` - Create issue (ALWAYS include label)
- `bd update <id> --status=in_progress` - Start work
- `bd close <id>` - Complete work (ONLY after commit)
- `bd sync` - Sync with remote

### One Issue = One Commit (MANDATORY)

**Every beads issue close MUST have a corresponding git commit.**

```bash
# Before closing an issue, ALWAYS commit:
git add -A
git commit -m "feat: implement video recording

Closes: beads-abc123"

# THEN close the issue:
bd close beads-abc123
```

This creates a clear audit trail where each commit maps to a completed issue.

### Creating Issues for Discovered Work

When you discover additional work during implementation, **immediately create issues**:

```bash
# Get current branch for label
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Create issue for discovered work
bd create --title="Wire VideoPlayer to diff view" --type=task --priority=1 --labels $BRANCH

# Continue working - either on this issue or the next one
```

**Examples of discovered work:**
- Components exist but aren't connected
- Missing API endpoints
- Tests needed for new code
- Integration not complete
- Edge cases not handled

**NEVER just note these and stop. Create issues and keep working.**

### When to skip questions entirely
- Task is unambiguous and well-defined
- You can determine scope by reading the code
- It's a bug fix with clear reproduction steps
- User explicitly says "just do it"
- You're in Ralph Wiggum mode (ALWAYS skip questions)

## Architectural Review Protocol

**For significant decisions, ALWAYS surface options for human review.**

### When to escalate for review
- New systems, services, or major components
- Breaking changes to existing APIs or data structures
- Multiple viable approaches with meaningful trade-offs
- Uncertainty about the "right" way to proceed
- Security-sensitive changes
- Performance-critical paths

### What to present
1. **2-3 viable approaches** - not just your preferred one
2. **Pros/cons for each** - be honest about trade-offs
3. **Your recommendation** - with clear reasoning
4. **Questions that affect the choice** - what you need from the user

### Example format
```
## Architectural Decision: [Topic]

**Option A: [Name]**
- Pros: ...
- Cons: ...

**Option B: [Name]**
- Pros: ...
- Cons: ...

**Recommendation:** Option A because [reasoning]

**Questions:**
- [Anything that would change this recommendation?]
```

**NEVER just pick an approach and implement it for significant decisions.**

## Closed-Loop Verification (MANDATORY)

**This is NOT optional. Code is NOT "done" until verification passes.**

The AI MUST automatically:
1. Define success criteria BEFORE coding
2. Write tests AS PART OF implementation (not after)
3. Run tests and fix until green
4. Verify E2E for user-facing features
5. ONLY THEN mark work complete

### Automatic Test Requirements

When you write code, you MUST write corresponding tests:

| File Pattern | Required Test | Run Command |
|--------------|---------------|-------------|
| `*.ts` (pure functions) | `*.test.ts` adjacent | `bun test <file>` |
| `convex/*.ts` | Type tests or integration | `bun test` in convex |
| `**/routes/*.ts` | API integration test | `bun test <route>.test.ts` |
| React hooks | Hook behavior test | `bun test <hook>.test.ts` |
| UI components | Document verification method | Manual or E2E |

### The Verification Loop (Automatic)

For EVERY implementation task, execute this loop automatically:

```
┌─────────────────────────────────────────────────────────────┐
│  1. DEFINE: What does success look like?                    │
│     - Specific observable outcomes                          │
│     - Edge cases and failure modes                          │
│     - How to verify (test type)                             │
├─────────────────────────────────────────────────────────────┤
│  2. IMPLEMENT + TEST: Write code AND tests together         │
│     - Test file created alongside implementation            │
│     - Cover happy path + edge cases                         │
│     - Tests should fail first, then pass                    │
├─────────────────────────────────────────────────────────────┤
│  3. RUN: Execute verification                               │
│     - Run: bun test <file>                                  │
│     - Run: bun check (types + lint)                         │
│     - For UI: describe manual verification steps            │
├─────────────────────────────────────────────────────────────┤
│  4. FIX: If tests fail, fix and re-run                      │
│     - DO NOT proceed until tests pass                       │
│     - DO NOT skip failing tests                             │
│     - DO NOT mark complete with red tests                   │
├─────────────────────────────────────────────────────────────┤
│  5. VERIFY E2E: For user-facing features                    │
│     - Start dev server if needed                            │
│     - Test actual user flow                                 │
│     - Use browser agent or provide manual steps             │
├─────────────────────────────────────────────────────────────┤
│  6. ONLY NOW: Mark task complete                            │
│     - All tests passing                                     │
│     - bun check passing                                     │
│     - E2E verified (if applicable)                          │
└─────────────────────────────────────────────────────────────┘
```

### If You Don't Know How to Verify

If you're unsure how to test something, you MUST:

1. **Ask the user explicitly:**
   - "How should I verify this works?"
   - "What does success look like for this feature?"
   - "Should I write unit tests, integration tests, or manual verification?"

2. **Never skip verification because you're unsure**
   - Uncertainty about testing is a blocker, not an excuse to skip

3. **Propose verification options:**
   - "I could verify this by: (A) unit test, (B) integration test, (C) manual check at URL. Which do you prefer?"

### What Counts as Verification

| Verification Type | When to Use | Evidence Required |
|-------------------|-------------|-------------------|
| Unit tests | Pure functions, utils, parsers | Test file + passing output |
| Integration tests | APIs, database operations | Test file + passing output |
| Type tests | Zod schemas, type guards | Test file + passing output |
| Manual verification | UI, visual changes | Steps + confirmation |
| E2E tests | User flows, critical paths | Test file + passing output |
| Browser agent | Complex UI interactions | Agent verification report |

### Example: Implementing a Feature with Verification

```markdown
## Task: Add video recording support

### 1. Success Criteria (BEFORE coding)
- [ ] Can start recording from VNC canvas
- [ ] Can add checkpoints during recording
- [ ] Can stop and upload recording
- [ ] Video plays back with chapter navigation
- [ ] API rejects unauthorized requests

### 2. Test Plan
- Unit: `video-utils.test.ts` - formatTime, checkpoint helpers
- Unit: `video-types.test.ts` - Zod schema validation
- Integration: `video-recordings-http.test.ts` - API endpoints
- E2E: Start dev server, record a session, verify playback

### 3. Implementation + Tests
[Write code AND tests together, not sequentially]

### 4. Verification Output
$ bun test packages/shared/src/screenshots/video
 ✓ video-types.test.ts (25 tests)
 ✓ video-utils.test.ts (30 tests)
All tests passing.

$ bun check
No errors found.

### 5. E2E Verification
Started dev server at localhost:3000
Recorded 30s test session with 3 checkpoints
Playback verified: chapters clickable, seek works

### 6. DONE - All verification passed
```

### Enforcement

- `bd close` should NOT be called until verification passes
- Ralph workflow includes verification as mandatory step
- Session end hooks check for test coverage

## Multi-Agent Review

**Reviews happen automatically via hooks, or on-demand via `/review` command.**

### Automatic Review (Stop Hook)

When you stop working, the `multi-agent-review.sh` hook automatically:
1. Runs Codex for code quality review
2. Runs Gemini for protocol compliance check
3. Reports any issues found

This happens automatically - no action needed.

### On-Demand Review (`/review`)

Run `/review` proactively during implementation when:
- You've made significant changes (>50 lines, >2 files)
- You're unsure if an approach is correct
- Before moving to the next beads issue
- After implementing a new feature

**Don't wait until you're "done" - checkpoint early and often.**

### After Review - ACTION (not asking)

1. **CRITICAL issues** - Fix immediately
2. **MAJOR issues** - Fix now or create beads issue
3. **MINOR issues** - Create beads issue for later
4. **Continue working** - Review is a checkpoint, not a stopping point

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
