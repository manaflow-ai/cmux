# TODO

## Socket API / Agent
- [x] Add window handles + `window.list/current/focus/create/close` for multi-window socket control (v2) + v1 equivalents (`list_windows`, etc) + CLI support.
- [ ] Add surface move/reorder commands (move between panes, reorder within pane, move across workspaces/windows).
- [ ] Add browser automation API inspired by `vercel-labs/agent-browser`, but backed by cmuxterm's WKWebView (wait, click, type, eval, screenshot, etc.).
- [ ] Finalize browser parity contract and command mapping decisions in `docs/agent-browser-port-spec.md`.
- [ ] Add `cmuxterm browser` command surface that mirrors agent-browser semantics and targets explicit `surface_id` handles.
- [ ] Add short handle refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`) and CLI `--id-format refs|uuids|both` output control.
- [ ] Add v1->v2 compatibility shim for migrated browser/topology commands while v1 remains supported.
- [ ] Port browser automation coverage to `tests_v2/` per `docs/agent-browser-port-spec.md` and keep v1 + v2 suites green.

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
