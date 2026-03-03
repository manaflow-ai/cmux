# crux

A cron task scheduler for terminal workflows, built on [cmux](https://github.com/manaflow-ai/cmux).

## Credits

crux is a focused fork. The heavy lifting comes from two projects:

- **[cmux](https://github.com/manaflow-ai/cmux)** by [manaflow-ai](https://github.com/manaflow-ai) -- the native macOS terminal with vertical tabs, split panes, notifications, and a scriptable API. crux inherits all of this.
- **[Ghostty](https://github.com/ghostty-org/ghostty)** by [Mitchell Hashimoto](https://github.com/mitchellh) -- the GPU-accelerated terminal engine that powers both cmux and crux via libghostty.

crux adds a task scheduler on top. Everything else is cmux.

## What crux adds

### Task Scheduler

A cron-based task runner that executes commands in Ghostty terminal surfaces. Tasks get full PTY support, ANSI rendering, scrollback, and interactivity.

- **Cron scheduling** -- 5-field expressions with wildcards, ranges, lists, and steps
- **Live terminal output** -- Each task runs in a dedicated Ghostty surface
- **Sidebar panel** -- View tasks, run status, and history (Cmd+J)
- **Titlebar toggle** -- Show/hide the scheduler from the titlebar
- **Notifications** -- Task completions trigger blue rings and badges
- **Task chaining** -- Chain tasks with `--on-success` and `--on-failure` hooks (max depth 3)
- **Git worktree isolation** -- Run tasks in isolated git worktrees (opt-in)
- **Session memory** -- Each task gets a context file via `CMUX_TASK_CONTEXT_FILE`
- **CLI** -- `cmux scheduler` subcommands for all operations
- **Socket API** -- 10 `scheduler.*` v2 commands

### Browser kill-switch

Disable the WKWebView browser via UserDefaults. All browser paths return errors when disabled.

```bash
defaults write com.cmuxterm.app browserEnabled -bool false
defaults write com.cmuxterm.app browserEnabled -bool true
```

## Scheduler

### Cron syntax

Standard 5-field format: `minute hour day-of-month month day-of-week`

| Field | Range | Special Characters |
|-------|-------|--------------------|
| Minute | 0-59 | `*` `,` `-` `/` |
| Hour | 0-23 | `*` `,` `-` `/` |
| Day of month | 1-31 | `*` `,` `-` `/` |
| Month | 1-12 | `*` `,` `-` `/` |
| Day of week | 0-7 (0 and 7 = Sunday) | `*` `,` `-` `/` |

When both day-of-month and day-of-week are restricted, the task fires when **either** matches (POSIX behavior).

Examples: `*/5 * * * *` (every 5 min), `0 9 * * 1-5` (9 AM weekdays), `0 0 1,15 * *` (midnight on 1st and 15th).

### CLI

```bash
cmux scheduler list --json

cmux scheduler create --name "hourly-build" --cron "0 * * * *" --command "make build"

cmux scheduler create --name "test-suite" --cron "0 */2 * * *" \
  --command "npm test" --working-directory ~/project \
  --on-failure <notify-task-id>

cmux scheduler enable <task_id>
cmux scheduler disable <task_id>
cmux scheduler run <task_id>
cmux scheduler cancel <run_id>
cmux scheduler logs --task-id <id> --limit 10
cmux scheduler delete <task_id>
```

### Socket API

Ten v2 socket commands:

| Command | Description |
|---------|-------------|
| `scheduler.list` | List all tasks |
| `scheduler.create` | Create a task |
| `scheduler.delete` | Delete a task |
| `scheduler.update` | Update a task (socket-only) |
| `scheduler.enable` | Enable a task |
| `scheduler.disable` | Disable a task |
| `scheduler.run` | Trigger a manual run |
| `scheduler.cancel` | Cancel a running task |
| `scheduler.logs` | Fetch run history |
| `scheduler.snapshot` | Read terminal output (socket-only) |

### Environment variables

Commands run by the scheduler receive these variables:

| Variable | Description |
|----------|-------------|
| `CMUX_SCHEDULED_TASK_ID` | UUID of the task definition |
| `CMUX_SCHEDULED_TASK_NAME` | Human-readable task name |
| `CMUX_TASK_RUN_ID` | UUID of this specific run |
| `CMUX_TASK_CONTEXT_FILE` | Path to a JSON context file |
| `CMUX_WORKTREE_PATH` | Git worktree path (when isolation is active) |

### Configuration

| UserDefaults Key | Default | Description |
|------------------|---------|-------------|
| `schedulerWorktreeIsolation` | `false` | Run tasks in temporary git worktrees |

Engine limits: 10 concurrent tasks, 500 completed runs retained, 30-second evaluation interval, chain depth capped at 3.

### Keyboard shortcut

| Shortcut | Action |
|----------|--------|
| Cmd+J | Toggle scheduler panel |

## Inherited from cmux

crux inherits all cmux features. The highlights:

- **Vertical + horizontal tabs** with git branch, PR status, ports, and notification text
- **Split panes** -- horizontal and vertical
- **Notification rings** -- blue rings and badges when agents need attention
- **In-app browser** -- scriptable WKWebView with accessibility tree API
- **Scriptable CLI and socket API** -- workspaces, panes, keystrokes, browser automation
- **Session restore** -- layout, working directories, scrollback, browser state
- **Ghostty compatible** -- reads `~/.config/ghostty/config` for themes and fonts
- **Native macOS** -- Swift and AppKit, not Electron

See the [cmux README](https://github.com/manaflow-ai/cmux) for full documentation, keyboard shortcuts, and installation details.

crux tracks upstream cmux and may diverge over time.

## Development

### Setup

```bash
./scripts/setup.sh
```

This initializes submodules and builds GhosttyKit.

### Build

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```

### Run

```bash
./scripts/reload.sh --tag <tag>
```

Use `--tag` with a descriptive name for isolated builds that run alongside the main app.

### Test

Run unit tests on the macOS VM:

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" test'
```

See `CLAUDE.md` for architecture details, scheduler internals, and socket threading policy.

## License

Same license as upstream cmux: GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`).

See `LICENSE` for the full text.
