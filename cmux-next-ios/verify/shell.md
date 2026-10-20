# Shell verification (milestone 1)

Date: 2026-10-12. Branch `feat-cnx-ios-shell`. Evidence (git-ignored) is in
`cmux-next-ios/verify/evidence/2026-10-12/shell/`.

## What was checked

| Area | How | Result |
| --- | --- | --- |
| Build | `verify/build.sh` (XcodeGen, Xcode 27.0, Debug, simulator, ad-hoc signed so the keychain works) | Builds clean |
| Simulators | Headless `cmux-mobile-shell-ios26` (iOS 26.5) and `cmux-mobile-shell-ios27` (iOS 27.0), iPhone 17 Pro. No Simulator.app window | Both |
| Flows | `verify/shell-flows.sh <udid> <label> <dir>`: drawer, rubber band, settings, states, team editor, welcome, email, code, setup; dark and light | 36 recordings |
| Drawer motion | `verify/drawer_track.py` decodes every recorded frame (real timestamps) and tracks the card's tab bar edge | No jumps or reversals in any drawer gesture on iOS 26 or 27 (dark); light checked by frame strips |
| References | `verify/montage.py` strips, our frames next to the captures | See below |
| Real Stack Auth | Live `AuthCoordinator` over `StackClientApp` (dev project). DEBUG auto-login with the runtime's built-in dev credential; relaunch restores the session from the keychain; account teams load (`Stack teams: N` in the `dev.cmux.mobile` log) | Works. The test account has 0 teams, so the sidebar shows its empty state |

How the flows are driven: `-cmux-mobile-demo <name>` starts a DEBUG-only driver
(`CmuxMobileShell/DemoDriver.swift`). Drawer drags feed one finger position per display
frame into the container's own tracking path (`beginTracking` / `track` /
`endTracking`), so everything except the `UIPanGestureRecognizer` is the real
code. State is set with launch arguments (`-cmux-mobile-tab`, `-cmux-mobile-sidebar-open`,
`-cmux-mobile-email`, `-cmux-mobile-setup`) and environment (`CMUX_MOBILE_MOCK_AUTH`, `CMUX_MOBILE_CLEAR_AUTH`,
`CMUX_MOBILE_STACK_EMAIL` / `CMUX_MOBILE_STACK_PASSWORD`), all DEBUG only.

## Drawer, frame by frame

Per-frame card position (`drawer_track.py`), iOS 27 dark, for example:

- Slow drag open: the card follows the finger 1:1 in 7 to 9 pt steps per frame,
  then the `drawer` spring takes over at the release point and settles at the
  sidebar width (302 pt on a 402 pt screen) with no overshoot.
- Flick close and flick open: velocity carries into the spring; largest step
  about 40 pt per 16 ms frame at 1800 pt/s, monotonic, settles in about 0.45 s.
- Partial drag (below 0.4) springs back closed from where it was released.
- Rubber band: dragging 150 pt past open moves the card 50 pt (d / 3) and
  springs back.
- Tap on the card closes from rest (spring starts at zero velocity).

Strips: `drawer-open-frames-s27-dark.png` (10 frames across one open).

Bugs found and fixed in this pass:

1. The card did not move while tracking and then jumped on release. Cause:
   `viewDidLayoutSubviews` reset the offset during the drag because it checked
   the recognizer state, not tracking. Fixed with an explicit tracking flag.
2. Team editor at the medium detent collapsed the avatar into the title. Now a
   600 pt detent.
3. Email step placeholder rendered as a blue link (markdown autolink in a
   `LocalizedStringKey`) and the keyboard did not come up. Verbatim prompt and
   default focus.
4. Sidebar header sat 6 pt below the toolbar line. Aligned.
5. Live auth showed the mock team list. Live mode now shows only Stack teams.

## Reference comparisons

| Strip | Compared with | Notes |
| --- | --- | --- |
| `cmp-sidebar.png` | `chatgpt-03-sidebar`, `chatgpt-23-sidebar-selected-expanded`, `claude-01-sidebar` | Width 75%, push-aside card with 44 pt continuous corners, scrim, selected row `fillSelected` inset 10, header on the toolbar line. Team list, `+` menu and Invite only (product override: no account footer) |
| `cmp-settings.png` | `claude-07-settings`, `claude-08-settings-bottom`, `chatgpt-13-settings-bottom` | Inset grouped on black, 54 pt rows, line icons in `label`, green toggles, Transport menu picker, Log out alone in red, version footer |
| `cmp-states.png` | `chatgpt-06-codex-error-state`, `chatgpt-11-codex-connect-empty` | Same layout: glyph, title, secondary line, white inline capsule, text CTA. Skeleton rows, asleep and offline banner also captured |
| `cmp-editor.png` | `chatgpt-29-new-project-sheet` | Glass X, centered title, docked white Done |
| `cmp-onboarding.png` | `chatgpt-09-codex-pair-manual` (boxes) | Welcome (no reference captured), email step with CTA above the keyboard, 6 code boxes with focus ring, setup team pick |

## Remaining gaps

- The 1Password test account (item `sirnczouv25kkvpzlbhnpxpqo4`) could not be
  read: `op` returned "authorization timeout" (the desktop app was not
  unlocked). Real Stack sign-in was verified with the runtime's built-in DEBUG
  dev credential instead. Re-run with
  `CMUX_MOBILE_STACK_EMAIL=$(op read ...) CMUX_MOBILE_STACK_PASSWORD=$(op read ...) verify/record.sh ...`
  once 1Password is unlocked.
- Apple, Google and GitHub sign-in were not exercised end to end in the
  simulator (they need a person at the provider sheet). Apple uses the Stack
  SDK's native `ASAuthorizationController` path and needs the Sign in with
  Apple capability on a signed device build.
- Invite links need `CMUX_MOBILE_API_BASE` (the `cmux-mobile-api` Worker); without it the
  row shows a toast. Leave team and team members are not in the shared auth
  runtime yet (toast / "You" only). Macs are mock until presence lands.
- `CmuxMobileModelTests` were not run: `nx-remote` could not resolve `cmux-lawrence-2`.
- Light-mode drawer tracking is checked visually; `drawer_track.py` cannot find
  the light glass tab bar edge reliably.
- No Instruments hitch trace yet (PLAN verification bar); the frame analysis
  above is from simulator recordings, which drop static frames.
- The scripted Settings scroll leaves the version footer under the tab bar
  (programmatic `scrollTo` anchor); hand scrolling reaches it.
