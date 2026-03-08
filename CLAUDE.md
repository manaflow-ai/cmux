# cmux agent notes

## Initial setup

Run the setup script to initialize submodules and build GhosttyKit:

```bash
./scripts/setup.sh
```

## Local dev

After making code changes, always run the reload script with a tag to launch the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

When reporting a tagged reload result in chat, use the format for your agent type:

**Claude Code** (markdown link with correct derived-data path, cmd+clickable):
```markdown
=======================================================
[cmux DEV <tag-name>.app](file:///Users/lawrencechen/Library/Developer/Xcode/DerivedData/cmux-<tag-name>/Build/Products/Debug/cmux%20DEV%20<tag-name>.app)
=======================================================
```

**Codex** (plain text format):
```
=======================================================
[<tag-name>: file:///Users/lawrencechen/Library/Developer/Xcode/DerivedData/cmux-<tag-name>/Build/Products/Debug/cmux%20DEV%20<tag-name>.app](file:///Users/lawrencechen/Library/Developer/Xcode/DerivedData/cmux-<tag-name>/Build/Products/Debug/cmux%20DEV%20<tag-name>.app)
=======================================================
```

Never use `/tmp/cmux-<tag>/...` app links in chat output. If the expected DerivedData path is missing, resolve the real `.app` path and report that `file://` URL.

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

When rebuilding cmuxd for release/bundling, always use ReleaseFast:

```bash
cd cmuxd && zig build -Doptimize=ReleaseFast
```

`reload` = kill and launch the Debug app only (tag required):

```bash
./scripts/reload.sh --tag <tag>
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "cmux STAGING" (isolated from production cmux):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## Debug event log

All debug events (keys, mouse, focus, splits, tabs) go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

- Untagged Debug app: `/tmp/cmux-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/cmux-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/cmux-last-debug-log-path`

- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## E2E mac UI tests

Run UI tests on the UTM macOS VM (never on the host machine). Always run e2e UI tests via `ssh cmux-vm`:

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" -only-testing:cmuxUITests/UpdatePillUITests test'
```

## Basic tests

Run basic automated tests on the UTM macOS VM (never on the host machine):

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" build && pkill -x "cmux DEV" || true && APP=$(find /Users/cmux/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/cmux DEV.app" -print -quit) && open "$APP" --env CMUX_SOCKET_MODE=allowAll && for i in {1..20}; do [ -S /tmp/cmux-debug.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, tag, and push

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). The build number is auto-incremented and is required for Sparkle auto-update to work.

Manual release steps (if not using the command):

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: update `CHANGELOG.md`; docs changelog is rendered from it.

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->

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

## Socket control — reading and steering terminal panes

The cmux socket lets agents read terminal output and send input to any pane without touching the keyboard.

### Find the socket

```bash
ls /tmp/cmux*.sock
# Debug build (untagged):  /tmp/cmux-debug.sock
# Tagged debug build:      /tmp/cmux-debug-<tag>.sock
# Release:                 /tmp/cmux.sock
```

### Key commands

```bash
SOCK="/tmp/cmux-debug.sock"   # adjust to your build

# Discover layout
printf "list_workspaces\n"            | nc -U $SOCK
printf "list_surfaces <ws-uuid>\n"    | nc -U $SOCK

# Read a pane's screen (current workspace only, by index or surface UUID)
printf "read_screen 0 --lines 30\n"           | nc -U $SOCK
printf "read_screen 0 --lines 60 --scrollback\n" | nc -U $SOCK

# Send text / keys to a specific surface (no workspace switch needed)
printf "send_surface <surface-uuid> <text>\n" | nc -U $SOCK
printf "send_key_surface <surface-uuid> ctrl-c\n" | nc -U $SOCK

# Send to whatever pane is currently focused
printf "send some text here\n"        | nc -U $SOCK
printf "send_key ctrl-c\n"            | nc -U $SOCK
```

### Agent monitoring rules

- **Never use `select_workspace`** to spy on other agents — it visibly switches the user's active tab.
- `read_screen` by UUID only works for surfaces in the **current** workspace. To monitor a pane in another workspace without switching, coordinate via **MCP mail** (`cmux` / `cmuxcoder` agents) instead.
- Use `list_surfaces <ws-uuid>` to get surface UUIDs, then `send_surface <uuid>` to steer without changing focus.
- The coding agent's tab is named **`cmux_coder`** — it is a surface tab inside the `cmux:ubuntu` workspace, not a separate workspace.

### Finding a tab — always use workspace NAME

**Never rely on workspace index or surface index.** The user can switch workspaces at any time,
shifting indices. Always look up by workspace name:

```bash
# 1. Find workspace by name
printf "list_workspaces\n" | nc -U $SOCK
# Output example:
#   0: D267DC10-... cmux: ubuntu
# * 1: 9075D919-... exp: statusline   ← user may be here, irrelevant
#   2: 258EB4B4-... o: mctrl

# 2. Get surfaces in the named workspace
WS_UUID=$(printf "list_workspaces\n" | nc -U $SOCK | grep "cmux: ubuntu" | grep -oE '[A-F0-9-]{36}')
printf "list_surfaces $WS_UUID\n" | nc -U $SOCK
# Output:
#   * 0: 87DB76A9-...   supervisor
#     1: F05FCE84-...   cmux_coder

# 3. Send by UUID — works regardless of which workspace user has focused
printf "send_surface F05FCE84-ECA7-4944-BCAA-7DFFC105D0D9 your message\n" | nc -U $SOCK
```

`read_screen` and `send_surface` behave differently across workspaces:

| Command | Cross-workspace by UUID? |
|---|---|
| `read_screen <uuid>` | ❌ fails — only works in current workspace |
| `send_surface <uuid> <text>` | ✅ works — delivers even if not current workspace |

### Typing into another agent's pane (human simulation)

`send_surface` types text into the input box but does **not** submit. Use `send_key_surface enter` to submit.

```bash
UUID="F05FCE84-ECA7-4944-BCAA-7DFFC105D0D9"  # cmux_coder

# Pattern: clear → type → enter
printf "send_key_surface $UUID ctrl-a\n" | nc -U $SOCK
printf "send_key_surface $UUID ctrl-k\n" | nc -U $SOCK
printf "send_surface $UUID your message here\n" | nc -U $SOCK
sleep 0.2
printf "send_key_surface $UUID enter\n" | nc -U $SOCK
```

If `send_surface` returns `ERROR: Failed to send input` — the terminal is busy running a command. Wait and retry.

**Surface layout in `cmux: ubuntu` workspace (UUID: D267DC10-B8C2-437C-B481-2AFD3167BA69):**
- Surface `0` (UUID: `87DB76A9-60A8-43FC-BFC2-51A5DECEA9B8`) = supervisor (cmux)
- Surface `1` (UUID: `F05FCE84-ECA7-4944-BCAA-7DFFC105D0D9`) = coder (cmux_coder)
