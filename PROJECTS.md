# PROJECTS

Cross-project tracking (features, bugs, backlog) for cmuxterm.

## Done
- 2026-02-08: Stabilized nested splits (no more "existing split disappears" during nested L/R splits) and added regression tests.
- 2026-02-08: Fixed "frozen" terminal panes/tabs (input not visible until Enter/unfocus) and added visual typing + HTML report tooling.
- 2026-02-08: Removed bonsplit tab content crossfade + selection animation to reduce flashes/blanking during pane/tab changes.
- 2026-02-09: Show unread notification badge as a blue dot in bonsplit tabs.
- 2026-02-09: Fixed `./scripts/reload.sh` single-instance safety check on macOS (use `ps etime` parsing instead of GNU-only `etimes`).
- 2026-02-09: Fixed Cmd+W close panel confirmation path not closing when a running-process dialog appears (bypass Bonsplit delegate gating after user confirms).
- 2026-02-09: Fixed WKWebView consuming app menu shortcuts (e.g. Cmd+N/Cmd+W, tab switching) by routing key equivalents through the main menu first; added unit tests and UI-test coverage scaffolding.
- 2026-02-09: Centralized customizable shortcut definitions and wired titlebar button tooltips to show effective shortcuts.
- 2026-02-10: Sidebar workspace close keeps focused index stable when possible (prefer focusing the next workspace, not the one above).
- 2026-02-10: Closing Bonsplit tabs keeps focused index stable when possible (prefer focusing the next tab, not the one above).

## Backlog
- Browser panels: investigate intermittent crash/relaunch around WKWebView lifecycle and focus notifications.
- Keyboard shortcuts: expand VM XCUITest coverage for focus + shortcuts (once Automation Mode is reliably enabled in the VM).
- Socket API: tighten/standardize semantics around split insertion side (left/right/up/down) and pane selection (UUID vs index) across CLI/docs/server.
- CLI: add an `it2`-compatible CLI shim (same subcommands/flags where feasible) that maps to cmuxterm's socket API and ships in `Contents/Resources/bin`.
