# Fork Customizations

Tracks what `rodchristiansen/cmux` adds on top of `manaflow-ai/cmux`. Keep this in sync when merging or cherry-picking.

**Baseline** (last updated 2026-04-12):
- Fork HEAD: `e1d0a7cb` — v0.64.6
- Upstream HEAD: `4fb28266`
- Merge base: `179b16c`
- Fork ahead by **46 commits** / behind by **105 commits**

Upstream syncs go through the permanent `sync-upstream` branch — never merge `upstream/main` directly into `main`.

---

## Features

### macOS 26 (Tahoe) Liquid Glass design
Adopt the Tahoe Liquid Glass design language for cmux's chrome, toolbar, titlebar, sidebar controls, notifications popover, and app icon. Keeps legacy titlebar controls out of macOS 26 while preserving behavior on earlier macOS versions.

Key commits:
- `10f2d7a7` Adopt macOS 26 Liquid Glass design
- `1951e3a4`, `65db12cb` PR review feedback follow-ups
- `2c3e61d3` Notifications popover, toolbar, sidebar controls for macOS 26
- `54f5b5c7` Compile `AppIcon.icon` for Tahoe Icon & Widget style
- `df47ffe5` Sidebar rows fill width; remove legacy titlebar controls

### Collapsible sidebar sections
User-defined named groups in the sidebar. Workspaces can belong to a section, section membership persists across restarts, sections can be renamed inline, collapsed/expanded, and reordered.

Key commits:
- `853003fa` Add collapsible user-defined sidebar sections
- `8d3c5789` Add `SidebarSection.swift` to Xcode project
- `14a0980b`, `352ad20c`, `0519a81b` Reactivity, persistence, divider-position, auto-rename fixes
- `7662ddef`, `6a152541`, `93a9341e` `workspace target:current` + section rename focus races
- `2f90041e`, `69e64395` PR review feedback

Source of truth: `Sources/SidebarSection.swift`, membership persisted via `SessionSidebarSectionSnapshot` in `Sources/SessionPersistence.swift`.

### Native workspace set (`workspace-set.json`)
Read `~/.config/cmux/workspace-set.json` on fresh launch and merge its sections + workspaces + panel templates + split layout into the running app. Replaces the external Python `cmux-import` script that killed cmux and wrote the session file directly.

Menu items:
- **cmux > Reload Workspace Set** — imports new entries live; rebuilds idle workspaces to match the template (running ones are preserved)
- **cmux > Rebuild Workspace Layout** — nuclear rebuild of the focused workspace from the template

JSON format supports `defaultPanels` (title + command) and a `defaultLayout` tree mirroring the session's split/pane structure (with `orientation`, `dividerPosition`, and panel-title references).

Key commits:
- `5e0cada5` Add native workspace set import
- `37ef416f` Apply `defaultPanels` template on create and reload
- `a3557e96` Honor `defaultLayout` (nested splits + divider positions)
- `607e6617` Rebuild: reset to one pane before restore (fixes compounding on repeat rebuilds)
- `827e602b` Rebuild: actually run the panel commands (resolve panels by custom title post-restore)

Files: `Sources/WorkspaceSetImporter.swift`, hooks in `Sources/AppDelegate.swift`, menu items in `Sources/cmuxApp.swift`. External docs in `~/Developer/Setup/cmux/cmux-workspace-restore.md`.

### Configurable agent roster (`agents:`)
The agents a workspace can run used to be a Swift enum with a case each for Claude and Codex, so adding a third — or telling `claude` apart from `claude-remote` — meant editing source, rebuilding and notarizing. They now come from an optional `agents:` block in the workspace-set file, read on every parse, so adding one is an edit plus **Reload Workspace Set**.

```yaml
agents:
- title: Claude
  command: claude-remote
  sessionPrefix: ""
- title: Codex
  command: codex-remote
  sessionPrefix: "cx-"
- title: Copilot
  command: copilot-remote
  sessionPrefix: "cp-"
- title: Claude (no tmux)
  command: claude
  sessionPrefix: "lc-"
```

`sessionPrefix` is what that agent's wrapper puts on its tmux session name, so two agents on one directory never attach the same session; at most one agent may leave it empty, and an agent that starts no tmux session (a bare CLI) just needs a prefix nothing else uses. `id` is optional and defaults to the command's own name (`claude-remote`, not `claude`) — it is what the CLI's `agent` argument accepts and what a workspace persists as its remembered choice. Because the id is the command, a wrapper and the bare CLI it wraps can both sit in one roster and be picked separately per workspace. A name that matches no id falls back to the first entry of that family, so a workspace that remembered the old enum's `claude` still resolves. Omitting the block entirely keeps the built-in Claude/Codex pair, so every workspace-set written before this behaves unchanged.

Retargeting a pane runs the roster's `command` verbatim, keeping only the pane's env prefix and arguments: `CLAUDE_REMOTE_HOST=win-desktop claude-remote -n win` picked over to Codex becomes `CLAUDE_REMOTE_HOST=win-desktop codex-remote -n win`. The roster is where "what this agent runs" is decided, which is what makes picking `claude` on a pane that ran `claude-remote` actually mean something.

**Where the pick lives.** Each workspace has its own **Agent** submenu (sidebar context menu and the View menu's workspace section), with a checkmark on its current agent and a *From Workspace Set* item that forgets the pick. **Duplicate Workspace** offers the same list plus *Same Agent*. **Reload Workspace Set** and **Rebuild Workspace Layout** carry no agent pick at all — a reload is the sidebar's cascade of rows, sections and panels, and it leaves every workspace on the agent it is set to. Scripted: `cmux rebuild-workspace --agent <id>`.

Files: `WorkspaceSetAgent` / `WorkspaceAgent` in `Sources/WorkspaceSetImporter.swift`, `setWorkspaceAgent` in `Sources/AppDelegate.swift`, `WorkspaceAgentMenu` in `Sources/cmuxApp.swift`, menus in `Sources/ContentView.swift`. The roster is published from `parseFile` and read under a lock, because it is loaded on the main actor but matched against commands and session names from nonisolated code.

### AutoApply: per-workspace commands on tab switch
Workspace-level hook that runs a configured command the first time a workspace is focused in a session. Tracks per-session, fires once per workspace regardless of layout.

Key commits:
- `ad605e1b` Add autoApply for workspace commands on tab switch
- `2e9b4416` Direct workspace selection observer
- `c4378cf4` Check pane count instead of panel count
- `27ddeee1` Per-session tracking; fire once regardless of layout

### Sidebar filter bar (Running / Idle / Clear)
Three-state filter above the sidebar workspace list:
- **Running** chip — only workspaces with a running status entry
- **Idle** chip — only workspaces without
- **Clear** (yellow) — appears whenever a filter is active
- Chips auto-disable when their set is empty; active filters auto-clear if the target set drops to zero, so the sidebar never appears mysteriously blank

Key commits:
- `43dfbe4e` Initial running-only filter
- `452521f1` Extend to Running + Idle + auto-clear semantics

Storage: `@AppStorage("sidebar.filter.mode")` in `Sources/ContentView.swift`.

### Sidebar toggle keyboard shortcut
Reintroduce the sidebar show/hide toggle with `⌃⌘S`, a leading chevron button, and strip the system-provided disclosure on macOS 26.

Key commits:
- `2d1e8477` Add leading button, strip system chevron, use `⌃⌘S`
- `8f6b841a` Revert chevron stripper in favor of removal approach

---

## Fixes

### Theme sync across light/dark mode
Theme inconsistency across panels was a recurring issue: surfaces would latch on to a stale view-hierarchy appearance and never recover.

Fixes:
- `7beb398f` Terminal surfaces losing theme after config reload
- `60aa5e58` Theme sync when system appearance changes while cmux is inactive
- `f0ce2ff7` Authoritative `NSApp.effectiveAppearance` + global surface sweep (the per-view `effectiveAppearance` can be stale; the system value is the one source of truth)

---

## Workflow

- **Sync-upstream gateway:** Always go through the permanent `sync-upstream` branch when pulling from `upstream/main`. Full merge of current upstream delta requires manual resolution in `Sources/ContentView.swift` (sidebar section rendering vs upstream's richer `TabItemView`), `Sources/GhosttyTerminalView.swift` (theme-sync + upstream's ZDOTDIR fix), `Sources/Workspace.swift` (Tahoe tab-bar hide vs upstream's configurable `tabTitleFontSize`), plus submodule bumps for `ghostty` and `vendor/bonsplit`.
- **Release:** Bump via `./scripts/bump-version.sh <version>` (explicit version skips the upstream appcast curl). Build / sign / notarize / install locally with `~/Developer/Setup/cmux/cmux-build-install.sh`. The upstream `scripts/build-sign-upload.sh` hardcodes manaflow signing/Sparkle/upload paths — the local script strips those.

---

## Versions shipped from this fork

| Version | Tag | Summary |
|---------|-----|---------|
| 0.64.6 | `v0.64.6` | Rebuild actually runs tools; Reload rebuilds idle workspaces |
| 0.64.5 | `v0.64.5` | Sidebar filter bar (Running + Idle + Clear) |
| 0.64.4 | `v0.64.4` | Rebuild resets to one pane before restore |
| 0.64.3 | `v0.64.3` | Theme drift fix (authoritative system appearance) |
| 0.64.2 | `v0.64.2` | Honor `defaultLayout` in `workspace-set.json` |
| 0.64.1 | `v0.64.1` | `defaultPanels` template on create + reload; Rebuild Workspace Layout menu item |
| 0.64.0 | `v0.64.0` | Native workspace set import |

---

## Related branches on the fork

- `feature/workspace-set-import` — in sync with main (carries all workspace-set fixes)
- `fix/workspace-set-reload-stuck-panels` — in sync with main (same)
- `sync-upstream` — permanent gateway branch for upstream merges
