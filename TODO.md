# TODO

## Socket API / Agent
- [x] Add window handles + `window.list/current/focus/create/close` for multi-window socket control (v2) + v1 equivalents (`list_windows`, etc) + CLI support.
- [ ] Add surface move/reorder commands (move between panes, reorder within pane, move across workspaces/windows).
- [ ] Add browser automation API inspired by `vercel-labs/agent-browser`, but backed by cmuxterm's WKWebView (wait, click, type, eval, screenshot, etc.).

## Command Palette
- [ ] Add cmd+shift+p palette with all commands

## Claude Code Integration
- [ ] Add "Install Claude Code integration" menu item in menubar
  - Opens a new terminal
  - Shows user the diff to their config file (claude.json, opencode config, codex config, etc.)
  - Prompts user to type 'y' to confirm
  - Implement as part of `cmuxterm` CLI, menubar just triggers the CLI command

## Additional Integrations
- [ ] Codex integration
- [ ] OpenCode integration

## UI/UX Improvements
- [ ] Add question mark icon to learn shortcuts
- [ ] Notification popover: each button item should show outline outside when focused/hovered
- [ ] Notification popover: add right-click context menu to mark as read/unread

## Analytics
- [x] Add PostHog tracking (set `PostHogAnalytics.apiKey` in `Sources/PostHogAnalytics.swift`)
