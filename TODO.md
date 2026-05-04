# TODO

## iOS cmx Sync
- [x] Render iOS terminal with actual libghostty/GhosttyKit instead of `libghostty-vt`
- [x] Feed PTY bytes into Ghostty and route iOS input back through terminal-scoped state
- [x] Dogfood simulator rendering, colors, and typing with tagged app `gsty`
- [x] Add Swift `cmx` MessagePack codec coverage for `Hello`, `PtyBytes`, `Input`, framing, ticket routes, token redaction, and launch dogfood hooks
- [x] Add iOS Stack/Rivet pairing proof code that matches the Rust iroh bridge HMAC test vector
- [x] Add Rust native `libghostty` renderer mode: iOS requests raw PTY replay/live PTY bytes instead of server `TerminalGridSnapshot`
- [x] Decode Rust `NativeSnapshot` on iOS and replace demo workspace/space/tab state with Rust-owned state after connect
- [x] Replace connected-mode local echo with a real `cmx` WebSocket dev stream for `Hello`/`PtyBytes`/`Input` dogfood
- [x] Switch iOS dev attach to `HelloNative` + `NativeInput` + `NativeLayout` so visible terminal input and resize target the Rust tab id
- [x] Dogfood simulator against a real Rust `cmx server --ws-bind 0.0.0.0:8787 --auth-token dev`; typed text renders back through Ghostty, proving the two-way stream
- [x] Add behavior coverage for the real libghostty renderer: unchanged PTY bytes, surface creation, ANSI output rendering, and outbound input
- [x] Add iMessage-style node/workspace inbox shell with full-width conversation rows and node pins
- [x] Copy the rail/resize bounds helper from the previous iOS branch and add a tmux dogfood test that verifies it tracks maximum pane size after resize
- [x] Carry non-secret node metadata in iroh bridge tickets and use it for connected iOS node rows
- [x] Handle Stack Auth native callbacks on iOS, persist tokens in Keychain, and require a stored Stack session before using `rivet_stack` tickets
- [x] Fetch and validate Stack-authenticated Rivet pairing secrets before a production ticket opens transport
- [x] Keep the iPad terminal inside the split-view detail column and resize the Ghostty surface above the software keyboard/accessory bar
- [x] Visually dogfood one shared shell across iPhone simulator, iPad simulator, and `cmx attach`, including the `lawrence in ~/fun/cmux-cli on main λ` prompt and iPhone-typed output appearing in cmux-tmux
- [x] Verify Rust daemon integration coverage for `Hello`/`PtyBytes`/`Input`, native `libghostty` PTY byte streaming, native layout resize, attached native client layouts, and the rail/bounds resize helper
- [x] Add a reusable Rust iroh client connector that decodes bridge tickets, proves Rivet pairing-secret possession, and opens an authenticated cmx stream for the future iOS binding
- [x] Expand the iOS terminal keyboard action scroller with terminal actions, one-shot/sticky Ctrl/Alt/Shift modifiers, and Mac-only Cmd affordances inferred from connected node metadata
- [x] Add the real iroh transport for production tickets without a WebSocket route, while keeping explicit WebSocket routes as a dev fallback
- [x] Add committed iOS UI automation coverage that types into Ghostty and verifies the rendered terminal output in CI
- [x] Add Stack-authenticated iOS hive discovery so a configured Rivet endpoint replaces the demo node/workspace inbox before terminal attach
- [x] Implement the production Rivet actor/API for signed-in hive discovery records

## Issue 151: Remote SSH (Living Execution)
- [x] `cmux ssh` creates remote workspace metadata and does not require `--name`
- [x] Remote daemon bootstrap/upload/start path with `cmuxd-remote serve --stdio`
- [x] Reconnect/disconnect controls (CLI/API/context menu) + improved error surfacing
- [x] Retry count/time surfaced in remote daemon/probe error details
- [ ] Remove automatic remote service port mirroring (`ssh -L` from detected remote listening ports)
- [ ] Add transport-scoped proxy broker (SOCKS5 + HTTP CONNECT) for remote traffic
- [ ] Extend `cmuxd-remote` RPC beyond `hello/ping` with proxy stream methods (`proxy.open|close`)
- [ ] Auto-wire WKWebView in remote workspaces to proxy via `WKWebsiteDataStore.proxyConfigurations`
- [ ] Add browser proxy e2e tests (remote egress IP, websocket, reconnect continuity)
- [x] Implement PTY resize coordinator with tmux semantics (`smallest screen wins`)
- [x] Add resize tests for multi-attachment sessions (attach/detach/reconnect transitions)

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

## Browser
- [ ] Per-WKWebView proxy observability/inspection once remote proxy path is shipped (URL, method, headers, body, status, timing)

## Bugs
- [ ] **P0** Terminal title updates are suppressed when workspace is not focused (e.g. Claude Code loading indicator doesn't update in sidebar until you switch to that tab)
- [ ] Sidebar tab reorder can get stuck in dragging state (dimmed tab + blue drop indicator line visible) after drag ends
- [ ] Drag-and-drop files/images into terminal shows URL instead of file path (Ghostty supports dropping files as paths)
- [ ] After opening a browser tab, up/down arrow keys (and possibly other keyboard shortcuts) stop working in the terminal
- [ ] Notification marked unread doesn't get pushed to the top of the list
- [ ] Browser cmd+shift+H ring flashes only once (should flash twice like other shortcuts)

## Refactoring
- [ ] **P0** Remove all index-based APIs in favor of short ID refs (surface:N, pane:N, workspace:N, window:N)
- [ ] **P0** CLI commands should be workspace-relative using CMUX_WORKSPACE_ID env var (not focused workspace) so agents in background workspaces don't affect the user's active workspace. Affected: send, send-key, send-panel, send-key-panel, new-split, new-pane, new-surface, close-surface, list-panes, list-pane-surfaces, list-panels, focus-pane, focus-panel, surface-health
- [ ] **P0** Remove `close-workspace` with no args — require explicit workspace short ID or UUID, with clear error message if missing

## UI/UX Improvements
- [ ] Show loading indicator in terminal while it's loading
- [ ] Add question mark icon to learn shortcuts
- [ ] Notification popover: each button item should show outline outside when focused/hovered
- [ ] Notification popover: add right-click context menu to mark as read/unread
- [ ] Right-click tab should allow renaming that workspace
- [ ] Cmd+click should open links in cmux (browser panel) instead of external browser
- [ ] "Waiting for input" notification should include custom terminal title if set
- [ ] Close button for current/active tab should always be visible (not just on hover)
- [ ] Add browser icon to the left of the plus button in the tab bar

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
