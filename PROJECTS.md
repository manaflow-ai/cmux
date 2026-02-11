# PROJECTS

Cross-project tracking (features, bugs, backlog) for cmuxterm.

## Done
- 2026-02-08: Stabilized nested splits (no more "existing split disappears" during nested L/R splits) and added regression tests.
- 2026-02-08: Fixed "frozen" terminal panes/tabs (input not visible until Enter/unfocus) and added visual typing + HTML report tooling.
- 2026-02-08: Removed bonsplit tab content crossfade + selection animation to reduce flashes/blanking during pane/tab changes.
- 2026-02-09: Show unread notification badge as a blue dot in bonsplit tabs.
- 2026-02-09: Multi-window support (Cmd+Shift+N) with per-window workspaces; notifications, notification popover, and Cmd+Shift+U route to the correct window; added UI test coverage.
- 2026-02-09: Cmd+Shift+W now labeled "Close Workspace" and confirmation dialog text uses "workspace" (not "tab"); added UI test coverage and de-flaked multi-window notification UI-test setup timing.
- 2026-02-09: Cmd+D now confirms the close confirmation dialog and closes the window when closing the last workspace.
- 2026-02-09: Suppressed Sparkle "Check for updates automatically?" permission prompt (rely on update pill only); added UI test coverage.
- 2026-02-09: Cmd+W close now uses "Close Tab" semantics (closes the focused tab; if it is the last tab, closes the workspace/window) and supports Cmd+D confirm when it would close the window; added UI test coverage.
- 2026-02-09: Ctrl+D shell exit no longer "recreates" a terminal when the last tab closes; it closes the workspace/window instead.
- 2026-02-09: Fixed dragging tabs moving the whole window by dynamically padding content below the actual titlebar height.
- 2026-02-09: Cmd+N now opens a new window when no windows are open; otherwise it creates a new workspace. Updated titlebar tooltip text to "New workspace" and added a UI test for the no-windows Cmd+N behavior.
- 2026-02-09: Fixed `./scripts/reload.sh` single-instance safety check on macOS (use `ps etime` parsing instead of GNU-only `etimes`).
- 2026-02-09: Fixed Cmd+W close panel confirmation path not closing when a running-process dialog appears (bypass Bonsplit delegate gating after user confirms).
- 2026-02-09: Fixed WKWebView consuming app menu shortcuts (e.g. Cmd+N/Cmd+W, tab switching) by routing key equivalents through the main menu first; added unit tests and UI-test coverage scaffolding.
- 2026-02-09: Centralized customizable shortcut definitions and wired titlebar button tooltips to show effective shortcuts.
- 2026-02-09: Regression: 2x2 split then close both right panels can leave the remaining top pane blank/frozen (no visual updates until focus changes). Fix: reassert Ghostty display ID after focusing to restart stuck CVDisplayLink; added screenshot-based UI regression test.
- 2026-02-10: Follow-up: closing both right splits could still produce a single transient "one frame blank" flash during relayout. Fix: ensure Bonsplit never renders an empty content view when tabs exist (fallback tab when `selectedTabId` is transiently nil), and remove synchronous `ghostty_surface_draw` / post-close refresh polling that caused rendering artifacts. UI test now captures a vsync-aligned screenshot timeline and asserts no post-close frame goes visually blank.
- 2026-02-10: Sidebar workspace close keeps focused index stable when possible (prefer focusing the next workspace, not the one above).
- 2026-02-10: Closing Bonsplit tabs keeps focused index stable when possible (prefer focusing the next tab, not the one above).
- 2026-02-10: Expanded bonsplit tab bar drop target so cross-pane tab drops work anywhere in the tab bar (including empty trailing space).
- 2026-02-10: bonsplit tab drag/drop: suppress no-op "drop to the right of itself" indicator (e.g. last tab dragged right) and avoid no-op move churn; added unit test coverage.
- 2026-02-10: bonsplit tab bar: fixed fade overlays appearing before the tab strip uses available width (tab strip now occupies full width up to split buttons; removed fade overlay animations).
- 2026-02-10: Browser address bar search now uses a configurable default search engine (Google, DuckDuckGo, Bing) and shows an omnibar dropdown (history + optional remote suggestions); added unit + UI tests (alignment, Ctrl+N/P). Also added Cmd+R reload and default Safari UA to avoid Google fallback/bot checks.
- 2026-02-10: Browser loading UI: removed omnibar progress indicator and replaced it with a spinning tab icon while the page is loading.
- 2026-02-10: Browser omnibar: added an explicit state machine (focus/editing/popup) so Escape and click-outside behaviors match Chrome; added regression tests.
- 2026-02-10: Added a customizable “Flash focused panel” keyboard shortcut (default Cmd+Shift+L) that visually highlights the currently focused terminal or browser panel.
- 2026-02-10: Added PostHog Swift SDK integration and a stable DAU signal (`cmuxterm_daily_active`, once per UTC day per install).
- 2026-02-10: Added a v2 JSON socket API (handle-based) and migrated the automated test suite to v2 while keeping v1 compatibility. Verified v1 + v2 suites passing on the VM (see `docs/v2-api-migration.md`).
- 2026-02-11: Extended the socket/CLI to handle multi-window automation: added v2 `window.list/current/focus/create/close`, v2 `workspace.move_to_window`, and included `window_id` in `system.identify` (plus caller validation). Added v1 window commands for the CLI (`list_windows`, etc). Added VM test coverage (`tests_v2/test_windows_api.py`) and verified v1 + v2 suites passing on the VM.
- 2026-02-11: Fixed split child-exit close semantics and focus indicator drift: exiting (`Ctrl+D`) one side of a split now only closes that pane (never the whole workspace due to transient panel-count state), and terminal first-responder focus now always re-syncs active bonsplit focus so blue focus indicators match actual keyboard focus. Added VM UI regression coverage for child-exit-in-split behavior.

## Backlog
- Browser panels: investigate intermittent crash/relaunch around WKWebView lifecycle and focus notifications.
- Keyboard shortcuts: expand VM XCUITest coverage for focus + shortcuts (once Automation Mode is reliably enabled in the VM).
- Socket API: tighten/standardize semantics around split insertion side (left/right/up/down) and pane selection (UUID vs index) across CLI/docs/server.
- CLI: add an `it2`-compatible CLI shim (same subcommands/flags where feasible) that maps to cmuxterm's socket API and ships in `Contents/Resources/bin`.
