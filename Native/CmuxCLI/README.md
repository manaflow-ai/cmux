# Native cmux CLI command manifest

`commands.json` is the compatibility inventory for the Rust CLI migration. It
contains every label in the Swift `switch command` dispatcher, including hidden
compatibility verbs. `scripts/generate-cli-docs.py` validates the inventory
against `CLI/cmux.swift` and renders this table.

## Agent contract

All commands accept the shared global presentation flags where supported:
`--output text|json|jsonl`, `--non-interactive`, `--dry-run`, and `--explain`.
JSON output is stdout-only; progress and diagnostics belong on stderr. The
`migration` column means `implemented` (Rust owns behavior), `delegated` (Rust
owns dispatch and delegates to a shared/app capability), or `fallback` (Swift
still owns behavior and Rust reports that boundary).

## Inventory

| Label | Rust ownership | Migration | Output | Side effects | Aliases | Nested verbs |
|---|---|---|---|---|---|---|
| `automation` | `swift-dispatch` | `fallback` | text, json | socket | none | `list`, `show`, `test`, `enable`, `disable`, `logs`, `reload` |
| `__sidebar_footer_icon_balance` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `__internal_flags` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `ping` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `iroh-diag` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `capabilities` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `agent-hibernation` | `swift-dispatch` | `fallback` | text, json | mutating | none | none |
| `vpn` | `cloud` | `implemented` | text, json | socket | none | none |
| `auth` | `swift-dispatch` | `fallback` | text, json | socket | `login`, `logout` | `status`, `login`, `logout` |
| `login` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `logout` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `agent` | `cloud` | `implemented` | text, json | mutating | none | none |
| `vm` | `cloud` | `implemented` | text, json | mutating | `cloud` | `domains`, `ls`, `list`, `new`, `create`, `open`, `port`, `status`, `info`, `prompt`, `skill`, `stats`, `top`, `resize`, `pause`, `resume`, `base`, `snapshot`, `checkpoint`, `fork`, `restore`, `rm`, `destroy`, `delete`, `promote-template`, `exec`, `run`, `route`, `agent`, `push`, `upload`, `pull`, `download`, `wait`, `env`, `layout`, `tree`, `workspace`, `terminal`, `tab`, `shell`, `attach`, `desktop`, `vnc`, `self`, `tools`, `tool-inspector`, `ports`, `handoff`, `ssh-info` |
| `cloud` | `cloud` | `implemented` | text, json | mutating | none | `domains`, `ls`, `list`, `new`, `create`, `open`, `port`, `status`, `info`, `prompt`, `skill`, `stats`, `top`, `resize`, `pause`, `resume`, `base`, `snapshot`, `checkpoint`, `fork`, `restore`, `rm`, `destroy`, `delete`, `promote-template`, `exec`, `run`, `route`, `agent`, `push`, `upload`, `pull`, `download`, `wait`, `env`, `layout` |
| `remotes` | `cloud` | `implemented` | text, json | socket | `remote` | `list`, `add`, `remove` |
| `remote` | `cloud` | `implemented` | text, json | socket | none | none |
| `ai-accounts` | `coderouter` | `delegated` | text, json | mutating | none | none |
| `coderouter` | `coderouter` | `delegated` | text, json | mutating | none | `status`, `machines`, `claude`, `agent` |
| `mobile` | `cloud` | `implemented` | text, json | socket | none | `set-font`, `compatible-tags` |
| `rpc` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `identify` | `topology` | `implemented` | text, json | socket | none | none |
| `list-windows` | `topology` | `implemented` | text, json | socket | none | none |
| `current-window` | `topology` | `implemented` | text, json | socket | none | none |
| `new-window` | `topology` | `implemented` | text, json | mutating | none | none |
| `focus-window` | `topology` | `implemented` | text, json | socket | none | none |
| `close-window` | `topology` | `implemented` | text, json | mutating | none | none |
| `move-workspace-to-window` | `topology` | `implemented` | text, json | mutating | none | none |
| `move-surface` | `topology` | `implemented` | text, json | mutating | none | none |
| `split-off` | `topology` | `implemented` | text, json | mutating | none | none |
| `reorder-surface` | `topology` | `implemented` | text, json | mutating | none | none |
| `reorder-workspace` | `topology` | `implemented` | text, json | mutating | none | none |
| `reorder-workspaces` | `topology` | `implemented` | text, json | mutating | none | none |
| `simulate-sidebar-drag` | `topology` | `implemented` | text, json | socket | none | none |
| `workspace-action` | `topology` | `implemented` | text, json | mutating | none | none |
| `tab-action` | `topology` | `implemented` | text, json | mutating | none | none |
| `move-tab-to-new-workspace` | `topology` | `implemented` | text, json | mutating | `detach-tab` | none |
| `detach-tab` | `topology` | `implemented` | text, json | mutating | none | none |
| `rename-tab` | `topology` | `implemented` | text, json | socket | none | none |
| `workspace-group` | `topology` | `implemented` | text, json | socket | none | none |
| `window` | `topology` | `implemented` | text, json | socket | none | `list`, `ls`, `current`, `displays`, `display`, `create`, `new`, `focus`, `close` |
| `canvas` | `swift-dispatch` | `fallback` | text, json | socket | none | `list`, `open`, `close`, `focus` |
| `simulator` | `simulator` | `delegated` | text, json | mutating | none | `list`, `boot`, `shutdown`, `install`, `launch` |
| `ios` | `simulator` | `delegated` | text, json | mutating | none | `list`, `boot`, `shutdown`, `install`, `launch` |
| `workspace` | `topology` | `implemented` | text, json | socket | `list-workspaces`, `new-workspace` | `list`, `ls`, `create`, `new`, `close`, `rm`, `delete`, `rename`, `select`, `focus`, `status`, `reconnect`, `disconnect`, `env`, `group` |
| `todo` | `topology` | `implemented` | text, json | socket | none | `list`, `add`, `check`, `uncheck`, `start`, `edit`, `rm`, `remove`, `clear`, `set`, `open` |
| `comments` | `notifications` | `implemented` | text, json | socket | none | `list`, `ls` |
| `layout` | `swift-dispatch` | `fallback` | text, json | socket | none | `get`, `set`, `apply` |
| `vault` | `notifications` | `implemented` | text, json | socket | none | `sessions`, `search`, `checkpoints`, `checkpoint`, `fork` |
| `list-workspaces` | `topology` | `implemented` | text, json | socket | none | none |
| `ssh` | `tmux` | `implemented` | text, json | mutating | `mosh` | `--forward-agent`, `--no-forward-agent`, `--transport`, `--command` |
| `mosh` | `tmux` | `implemented` | text, json | mutating | none | none |
| `mosh-tmux` | `tmux` | `implemented` | text, json | mutating | none | none |
| `ssh-tmux` | `tmux` | `implemented` | text, json | mutating | none | none |
| `local-tmux` | `tmux` | `implemented` | text, json | mutating | `tmux` | `start`, `attach`, `list`, `status`, `detach`, `close`, `cleanup` |
| `tmux` | `tmux` | `implemented` | text, json | mutating | none | `new-session`, `new`, `new-window`, `neww`, `split-window`, `splitw`, `list-panes`, `list-windows`, `select-pane`, `select-window`, `kill-window`, `kill-pane`, `send-keys`, `capture-pane` |
| `ssh-pty-attach` | `tmux` | `implemented` | text, json | socket | none | none |
| `ssh-session-list` | `tmux` | `implemented` | text, json | socket | none | none |
| `ssh-session-attach` | `tmux` | `implemented` | text, json | socket | none | none |
| `ssh-session-cleanup` | `tmux` | `implemented` | text, json | socket | none | none |
| `ssh-session-end` | `tmux` | `implemented` | text, json | socket | none | none |
| `vm-pty-attach` | `cloud` | `implemented` | text, json | socket | none | none |
| `vm-tui-connect` | `cloud` | `implemented` | text, json | socket | none | none |
| `vm-ssh-attach` | `cloud` | `implemented` | text, json | socket | none | none |
| `new-workspace` | `topology` | `implemented` | text, json | mutating | none | none |
| `new-split` | `topology` | `implemented` | text, json | mutating | none | none |
| `list-panes` | `topology` | `implemented` | text, json | socket | none | none |
| `list-pane-surfaces` | `topology` | `implemented` | text, json | socket | none | none |
| `tree` | `topology` | `implemented` | text, json | socket | none | none |
| `top` | `terminal` | `implemented` | text, json | socket | none | none |
| `memory` | `terminal` | `implemented` | text, json | socket | none | none |
| `focus-pane` | `topology` | `implemented` | text, json | socket | none | none |
| `new-pane` | `topology` | `implemented` | text, json | mutating | none | none |
| `new-surface` | `topology` | `implemented` | text, json | mutating | none | none |
| `surface` | `topology` | `implemented` | text, json | socket | `surface-resume` | `ls`, `list`, `tree`, `catalog`, `new`, `new-terminal`, `open`, `project`, `focus`, `close`, `create`, `split`, `split-off`, `move`, `reorder`, `health` |
| `restore` | `sessions` | `implemented` | text, json | mutating | none | none |
| `fork` | `sessions` | `implemented` | text, json | mutating | none | none |
| `surface-resume` | `swift-dispatch` | `fallback` | text, json | mutating | none | none |
| `close-surface` | `topology` | `implemented` | text, json | mutating | none | none |
| `drag-surface-to-split` | `topology` | `implemented` | text, json | mutating | none | none |
| `refresh-surfaces` | `terminal` | `implemented` | text, json | socket | none | none |
| `reload-config` | `terminal` | `implemented` | text, json | socket | none | none |
| `surface-health` | `terminal` | `implemented` | text, json | socket | none | none |
| `debug-terminals` | `terminal` | `implemented` | text, json | socket | none | none |
| `trigger-flash` | `terminal` | `implemented` | text, json | socket | none | none |
| `list-panels` | `topology` | `implemented` | text, json | socket | none | none |
| `focus-panel` | `topology` | `implemented` | text, json | socket | none | none |
| `close-workspace` | `topology` | `implemented` | text, json | mutating | none | none |
| `select-workspace` | `topology` | `implemented` | text, json | mutating | none | none |
| `rename-workspace` | `topology` | `implemented` | text, json | mutating | `rename-window` | none |
| `rename-window` | `topology` | `implemented` | text, json | mutating | none | none |
| `current-workspace` | `topology` | `implemented` | text, json | socket | none | none |
| `read-selection` | `terminal` | `implemented` | text, json | socket | none | none |
| `read-screen` | `terminal` | `implemented` | text, json | socket | none | none |
| `send` | `terminal` | `implemented` | text, json | mutating | none | none |
| `send-key` | `terminal` | `implemented` | text, json | mutating | none | none |
| `send-panel` | `terminal` | `implemented` | text, json | mutating | none | none |
| `send-key-panel` | `terminal` | `implemented` | text, json | mutating | none | none |
| `notify` | `notifications` | `implemented` | text, json | mutating | none | none |
| `list-notifications` | `notifications` | `implemented` | text, json | socket | none | none |
| `dismiss-notification` | `notifications` | `implemented` | text, json | mutating | none | none |
| `mark-notification-read` | `notifications` | `implemented` | text, json | mutating | none | none |
| `open-notification` | `notifications` | `implemented` | text, json | mutating | none | none |
| `jump-to-unread` | `notifications` | `implemented` | text, json | socket | none | none |
| `clear-notifications` | `notifications` | `implemented` | text, json | mutating | none | none |
| `set-status` | `notifications` | `implemented` | text, json | mutating | none | none |
| `clear-status` | `notifications` | `implemented` | text, json | mutating | none | none |
| `list-status` | `notifications` | `implemented` | text, json | socket | none | none |
| `set-progress` | `notifications` | `implemented` | text, json | mutating | none | none |
| `clear-progress` | `notifications` | `implemented` | text, json | mutating | none | none |
| `log` | `notifications` | `implemented` | text, json | mutating | none | none |
| `clear-log` | `notifications` | `implemented` | text, json | mutating | none | none |
| `list-log` | `notifications` | `implemented` | text, json | socket | none | none |
| `sidebar-state` | `notifications` | `implemented` | text, json | socket | none | none |
| `right-sidebar` | `notifications` | `implemented` | text, json | mutating | none | `open`, `close`, `toggle`, `focus`, `mode`, `set` |
| `sidebar` | `notifications` | `implemented` | text, json | mutating | none | `open`, `close`, `toggle`, `show`, `hide`, `focus`, `mode`, `set` |
| `claude-hook` | `hooks` | `delegated` | text | mutating | none | none |
| `codex-hook` | `hooks` | `delegated` | text | mutating | none | none |
| `feed-hook` | `hooks` | `delegated` | text | mutating | none | none |
| `hooks` | `hooks` | `delegated` | text | mutating | none | `catalog`, `list`, `setup`, `uninstall`, `enqueue`, `feed` |
| `set-app-focus` | `swift-dispatch` | `fallback` | text | mutating | none | none |
| `simulate-app-active` | `swift-dispatch` | `fallback` | text | mutating | none | none |
| `__tmux-compat` | `tmux` | `implemented` | text, json | socket | none | none |
| `__codex-teams-watch` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `capture-pane` | `tmux` | `implemented` | text | socket | none | none |
| `resize-pane` | `tmux` | `implemented` | text | socket | none | none |
| `pipe-pane` | `tmux` | `implemented` | text | socket | none | none |
| `wait-for` | `tmux` | `implemented` | text | socket | none | none |
| `swap-pane` | `tmux` | `implemented` | text | socket | none | none |
| `break-pane` | `tmux` | `implemented` | text | socket | none | none |
| `join-pane` | `tmux` | `implemented` | text | socket | none | none |
| `last-window` | `tmux` | `implemented` | text | socket | none | none |
| `last-pane` | `tmux` | `implemented` | text | socket | none | none |
| `next-window` | `tmux` | `implemented` | text | socket | `previous-window`, `last-window` | none |
| `previous-window` | `tmux` | `implemented` | text | socket | none | none |
| `find-window` | `tmux` | `implemented` | text | socket | none | none |
| `clear-history` | `tmux` | `implemented` | text | socket | none | none |
| `set-hook` | `tmux` | `implemented` | text | socket | none | none |
| `popup` | `tmux` | `implemented` | text | socket | none | none |
| `bind-key` | `tmux` | `implemented` | text | socket | `unbind-key`, `copy-mode` | none |
| `unbind-key` | `tmux` | `implemented` | text | socket | none | none |
| `copy-mode` | `tmux` | `implemented` | text | socket | none | none |
| `set-buffer` | `tmux` | `implemented` | text | socket | none | none |
| `paste-buffer` | `tmux` | `implemented` | text | socket | none | none |
| `list-buffers` | `tmux` | `implemented` | text | socket | none | none |
| `respawn-pane` | `tmux` | `implemented` | text | socket | none | none |
| `display-message` | `tmux` | `implemented` | text | socket | none | none |
| `help` | `swift-dispatch` | `fallback` | text, json | socket | none | none |
| `browser` | `browser` | `implemented` | text, json | mutating | none | `open`, `navigate`, `goto`, `back`, `forward`, `reload`, `url`, `get-url`, `snapshot`, `eval`, `wait`, `scroll`, `type`, `fill`, `press`, `select`, `screenshot`, `cookies`, `storage`, `tab`, `viewport`, `network`, `console`, `errors`, `state`, `profile` |
| `project` | `browser` | `implemented` | text, json | mutating | none | `list`, `open` |
| `open-browser` | `browser` | `implemented` | text, json | mutating | none | `open` |
| `navigate` | `browser` | `implemented` | text, json | mutating | none | none |
| `browser-back` | `browser` | `implemented` | text, json | mutating | none | none |
| `browser-forward` | `browser` | `implemented` | text, json | mutating | none | none |
| `browser-reload` | `browser` | `implemented` | text, json | mutating | none | none |
| `get-url` | `browser` | `implemented` | text, json | socket | none | none |
| `focus-webview` | `browser` | `implemented` | text, json | socket | none | none |
| `is-webview-focused` | `browser` | `implemented` | text, json | socket | none | none |
| `markdown` | `browser` | `implemented` | text, json | mutating | none | `open` |
