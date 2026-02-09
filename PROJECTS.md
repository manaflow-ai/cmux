# PROJECTS

Cross-project tracking (features, bugs, backlog) for cmuxterm.

## Done
- 2026-02-08: Stabilized nested splits (no more "existing split disappears" during nested L/R splits) and added regression tests.
- 2026-02-08: Fixed "frozen" terminal panes/tabs (input not visible until Enter/unfocus) and added visual typing + HTML report tooling.
- 2026-02-08: Removed bonsplit tab content crossfade + selection animation to reduce flashes/blanking during pane/tab changes.

## Backlog
- Browser panels: investigate intermittent crash/relaunch around WKWebView lifecycle and focus notifications.
- Keyboard shortcuts: ensure custom keybinds work when focus is inside WKWebView and add VM XCUITest coverage for focus + shortcuts.
- Socket API: tighten/standardize semantics around split insertion side (left/right/up/down) and pane selection (UUID vs index) across CLI/docs/server.
