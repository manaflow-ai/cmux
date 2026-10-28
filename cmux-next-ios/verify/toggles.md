# Toggle and control audit, team icon editor

Date: 2026-10-13. Branch `feat-cnx-ios-toggles`. Evidence (git-ignored) is in
`cmux-next-ios/verify/evidence/toggles/`: `before/` and `after/` stills, `glyph/`
recordings, `cmp-toggles-dark.png`, `cmp-glyph.png`.

## Bug

In Dark Mode every switch that was on showed as a white capsule: white track,
white knob (user screenshot `white-toggles.png`; reproduced in
`before/ios26-page-notifications-dark.png`). In Light Mode the same switches
were black. Cause: Settings, the team editor and the root tab view set the
neutral app tint `.tint(label)`, so the selected tab, menu values and
checkmarks read as label and not blue. A switch `Toggle` takes its on-track
color from the same tint. SPEC 1.2 and 2.1 call for system green (`success`).

## Fix

`CmuxMobileDesign/Controls.swift` adds `CmuxMobileSwitchToggleStyle` (`.toggleStyle(.cmuxMobileSwitch)`):
a `.switch` toggle tinted `success`, whatever tint surrounds it. The
`cmuxMobileNeutralControlTint()` modifier applies the neutral `label` tint plus that
style, and replaces the bare `.tint(label)` on `SettingsScreen` (all settings
pages and sheets presented from it inherit it) and `TeamAppearanceEditor`.
The root `.tint(label)` in `RootView` stays as is: the only toggles outside
Settings are menu items (checkmarks), and a custom style must not reach menus.

## How it was checked

Headless simulators `cmux-mobile-tog-ios26` (iOS 26.5) and `cmux-mobile-tog-ios27` (iOS 27.0),
iPhone 17 Pro, no Simulator.app window, mock auth. `verify/toggles-shots.sh
<udid> <label> <dir>` captures every Settings page in dark and light. It uses
two DEBUG hooks added for this: `-cmux-mobile-settings-page <route>` opens Settings on a
page, and the demos `settings-middle` and `settings-bottom` scroll the root list.
`-cmuxMobile.setupComplete YES` skips first-run setup through the UserDefaults argument
domain. Compared with `chatgpt-15-codex-settings-bottom` (green switches) and
`claude-08-settings-bottom` (blue; rejected by SPEC).

## Controls audited

| Screen | Control | Before (dark / light) | After (dark / light), iOS 26 and 27 |
| --- | --- | --- | --- |
| Settings | Show connection details (`Toggle`) | white on / black on | green on, gray off |
| Settings | Haptic feedback (`Toggle`) | white / black | green |
| Settings | Require Face ID (`Toggle`) | white / black | green |
| Settings > Developer (DEBUG) | Mock data (`Toggle`) | white / black | green |
| Settings > Notifications | Questions and permissions, Finished tasks, Errors (`Toggle`) | white / black | green |
| Settings > Terminal | Wrap code and diff lines, Key clicks (`Toggle`) | white / black | green |
| Settings > Composer | Dismiss keyboard after sending (`Toggle`) | white / black | green |
| Settings | Transport, Demo at next launch (`Picker .menu`) | label value + chevrons | unchanged, correct |
| Settings > Composer | Follow-up while running (`Picker .menu`) | label | unchanged, correct |
| Settings > Notifications | Live Activities (`Picker .menu`) | label | unchanged, correct |
| Settings > Terminal | Theme (`Picker .inline`, checkmark) | label checkmark | unchanged, correct |
| Settings > Terminal | Font size (`Stepper`) | system gray buttons, label glyphs | unchanged, correct |
| Settings | Appearance tiles (custom) | label ring | unchanged |
| Settings, Team, Account | Navigation rows, Log out, Leave team, Delete account | label / danger | unchanged |
| Team appearance sheet | Icon mode (`Picker .segmented`, new) | n/a | system segmented, readable both modes |
| Team appearance sheet | Character field (`TextField`) | n/a | label text, label3 placeholder |
| Team appearance sheet | Done (`PrimaryCapsule`), swatches | accent fill | unchanged |
| Workspaces filter menu | Show Offline Macs (`Toggle` in `Menu`) | menu checkmark | untouched (menu item, no switch) |
| Diff viewer menu | Wrap lines, Hide whitespace, Show viewed files (`Toggle` in `Menu`) | menu checkmark | untouched |
| Feed filter menu | Per-workspace (`Toggle` in `Menu`) | menu checkmark | untouched |
| Chat composer menu | Plan mode (`Toggle` in `Menu`) | menu checkmark | untouched |
| Artifact preview | Wrap lines (`Toggle` in bottom toolbar) | not reached | not reached: needs a live terminal artifact; no mock path. Follow-up |
| Buttons, onboarding | `ProgressView` tints (`onAccent`, `label`) | correct | unchanged |
| Terminal key bar, composer | `.tint(.primary)` buttons | correct | unchanged |
| Chief home | `.tint(Color(white: 0.35))`, `.tint(.indigo)` swipe actions | correct | unchanged |

No control now renders white on white or disappears in either mode.

## Team icon: Automatic, Custom, None

User request: the icon comes from the keyboard and allows any single character,
including emoji, plus None and Automatic (team's first letter).

- `TeamGlyph` (`CmuxMobileModel/Team.swift`): `.automatic`, `.custom(String)`, `.none`,
  mapped to the existing wire field: `emoji` null = Automatic, `""` = None,
  otherwise one grapheme. Unit tests in `TeamTests` (not run: `nx-remote` could
  not resolve `cmux-lawrence-2`).
- `TeamAvatar` draws nothing for None, an emoji at emoji size, and a typed
  letter, digit or symbol in white like the initial. Sidebar rows, Settings,
  Team page and the setup team picker all use it.
- Editor: "Icon" segmented control (Automatic / Custom / None) above the color
  grid so the preview stays visible over the keyboard. Custom shows an inline
  field on the default keyboard (emoji key reaches the emoji keyboard). It keeps
  one grapheme: a new keystroke replaces the old one wherever the cursor is,
  whitespace is ignored, an empty field previews and saves as Automatic.
- Backend: `PUT /v1/teams/:teamId/prefs` now accepts `emoji: ""` (and rejects
  whitespace). Tests in `backend/test/http.test.ts` (16 pass). PROTOCOL.md
  updated. Needs a redeploy of the Worker.

Recordings (`glyph/ios{26,27}-glyph-{dark,light}.mp4`, `verify/glyph-flow.sh`):
Custom, tap `k` on the software keyboard, switch to the emoji keyboard and tap
an emoji (it replaces `k`), None (color only), Automatic (`M`). All four pass.
Taps are AXe accessibility taps on the on-screen keys. `axe type` is not used:
HID typing attaches a hardware keyboard and hides the software keyboard for the
simulator's lifetime. The recordings use `axe record-video` because
`simctl io recordVideo` allows one recording per host and parallel agents held
it.

Not covered by the recordings: tapping Done and the saved avatar in the
sidebar (the avatar renders through the same `TeamAvatar` shown in the
preview). The iOS 27 `team-editor` stills were captured before the sheet rose;
the iOS 27 recordings show it.
