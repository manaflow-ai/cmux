# TODO

## Socket API / Agent
- [x] Add window handles + `window.list/current/focus/create/close` for multi-window socket control (v2) + v1 equivalents (`list_windows`, etc) + CLI support.
- [x] Add surface move/reorder commands (move between panes, reorder within pane, move across workspaces/windows).
- [x] Add browser automation API inspired by `vercel-labs/agent-browser`, but backed by cmux's WKWebView (wait, click, type, eval, screenshot, etc.).
- [x] Finalize browser parity contract and command mapping decisions in `docs/agent-browser-port-spec.md`.
- [x] Add `cmux browser` command surface that mirrors agent-browser semantics and targets explicit `surface_id` handles.
- [x] Add short handle refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`) and CLI `--id-format refs|uuids|both` output control.
- [x] Add v1->v2 compatibility shim for migrated browser/topology commands while v1 remains supported.
- [x] Port browser automation coverage to `tests_v2/` per `docs/agent-browser-port-spec.md` and keep v1 + v2 suites green.
  - Added `tests_v2/test_browser_api_comprehensive.py`, `tests_v2/test_browser_api_p0.py`, `tests_v2/test_browser_api_extended_families.py`, `tests_v2/test_browser_api_unsupported_matrix.py`, and `tests_v2/test_browser_cli_agent_port.py`.
  - Full VM runs: `./scripts/run-tests-v1.sh` and `./scripts/run-tests-v2.sh` passing (v2 visual D12 remains reported as a known non-blocking VM failure, matching v1 policy).
- [x] Fix `cmux browser open|open-split|new` URL parsing so routing flags (`--workspace`, `--window`) are removed before URL construction.
- [x] Fix `identify --workspace/--surface` caller parsing to honor ref handles (`workspace:N`, `surface:N`) instead of falling back to current/focused IDs.
- [x] Update `browser.open_split` placement policy: reuse nearest right sibling pane first (nested-aware), only create a new split when caller has no right sibling.
- [x] Upgrade `browser.snapshot` to agent-browser-style output (`snapshot` tree text + `refs`) and make non-JSON CLI output print snapshot content instead of `OK`.
- [x] Add richer selector failure diagnostics (`hint`, counts, sample, snapshot excerpt) with bounded retries for transient `not_found` races.
- [x] Add regression coverage for browser placement policy + snapshot/ref output + diagnostics in v2 tests.
- [x] Allow `browser fill` with empty text (clear input) in CLI + v2 API flows.
- [x] Make legacy `new-pane`/`new-surface` CLI output prefer short `surface:N` refs by default.
- [x] Add optional `--snapshot-after` / `snapshot_after` action feedback to include a fresh post-action browser snapshot.
- [x] Switch CLI `--json` default ID output to refs-first (UUIDs only via `--id-format uuids|both`) and add regression coverage.
- [x] Expand end-user skill docs with deep-linkable cmux-browser references/templates plus a new core `skills/cmux/` topology skill.

## Command Palette
- [ ] Add cmd+shift+p palette with all commands

## Feature Requests
- [ ] Warm pool of Claude Code instances mapped to a keyboard shortcut

## Claude Code Integration
- [ ] Add "Install Claude Code integration" menu item in menubar
  - Opens a new terminal
  - Shows user the diff to their config file (claude.json, opencode config, codex config, etc.)
  - Prompts user to type 'y' to confirm
  - Implement as part of `cmux` CLI, menubar just triggers the CLI command

## Additional Integrations
- [ ] Codex integration
- [ ] OpenCode integration

## UI/UX Improvements
- [ ] Add question mark icon to learn shortcuts
- [ ] Notification popover: each button item should show outline outside when focused/hovered
- [ ] Notification popover: add right-click context menu to mark as read/unread

## Analytics
- [x] Add PostHog tracking (set `PostHogAnalytics.apiKey` in `Sources/PostHogAnalytics.swift`)

### Browser Parity Completion (agent-browser port)
- [x] Implement locator family:
  - `browser.find.role`
  - `browser.find.text`
  - `browser.find.label`
  - `browser.find.placeholder`
  - `browser.find.alt`
  - `browser.find.title`
  - `browser.find.testid`
  - `browser.find.first`
  - `browser.find.last`
  - `browser.find.nth`
- [x] Implement frame/dialog/download:
  - `browser.frame.select`
  - `browser.frame.main`
  - `browser.dialog.accept`
  - `browser.dialog.dismiss`
  - `browser.download.wait`
- [x] Implement session/context state APIs:
  - `browser.cookies.get|set|clear`
  - `browser.storage.get|set|clear`
  - `browser.tab.new|list|switch|close`
  - `browser.state.save|load`
- [x] Implement developer/diagnostic helpers:
  - `browser.console.list|clear`
  - `browser.errors.list`
  - `browser.highlight`
  - `browser.addinitscript`
  - `browser.addscript`
  - `browser.addstyle`
- [x] Add explicit `not_supported` for WebKit/CDP-gap commands:
  - `browser.viewport.set`
  - `browser.geolocation.set`
  - `browser.offline.set`
  - `browser.trace.start|stop`
  - `browser.network.route|unroute|requests`
  - `browser.screencast.start|stop`
  - `browser.input_mouse|input_keyboard|input_touch`
- [x] Extend `cmux browser ...` CLI grammar for the new families (including aliases).
- [x] Port/add v2 tests for all newly implemented families.
- [x] Update unsupported matrix tests to assert `not_supported` for hard platform gaps (instead of `method_not_found`).
- [x] Re-run full `run-tests-v1.sh` and `run-tests-v2.sh` on `cmux-vm`.
