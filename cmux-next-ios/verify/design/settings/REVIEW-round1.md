# Settings round 1: designer review

Reviewer pass, 2026-10-14, against `SPEC.md` and the orchestrator overrides
(Relay only is Debug/Demo only; the Notifications permission row stays for
Chief's local alerts, with "Notifications from your Macs need the TestFlight
build" when the build has no push; item 14 known open). The implementer's
`round1/` captures were not used as evidence. Every result below comes from my
own builds and captures in `round1-review/`.

**Verdict: NOT SIGNED OFF.** There are 3 failing items (10, 14, 8-live) and
4 new findings (A to D). Items 1 to 7, 9, 11, 12 and 13 pass.

## Setup

- Source: `origin/feat-cnx-ios` `1311e6d57acc`, built in a separate review
  worktree that was removed afterwards. `xcodegen`, then simulator builds with
  `-jobs 4` and derived data in `/tmp/cmux-mobile-settings-review-dd`:
  - Debug: `dev.cmux.mobile.srevDebug`, built with `CMUX_MOBILE_TAG=.srevDebug`.
  - Production: `dev.cmux.mobile.prod`.
- Simulator: one headless iPhone 17 Pro on iOS 27.0, 402 x 874 pt at 3x,
  named `cmux-mobile-settings-review` (deleted afterwards). Input went through `axe`.
  The E2E rig was not used and the app was never paired with a Mac.
- **Mock (layout only).** Debug ran with `CMUX_MOBILE_MOCK_AUTH=1`, so the user,
  teams, Macs and presence are sample data. Layout, copy and motion are real.
- Production:
  - `scripts/check-production-binary.sh` reports `ok` (2 binaries, 29 strings
    checked).
  - `strings` finds no "Mock (layout", "layout only", "simulate distant" or
    "Not available in this build".
  - The two "relay only" hits are log strings in the Rust link library, not UI.
  - Caveat: the UI literal "Relay only" is 10 bytes. Swift stores short
    literals inline, so `strings` cannot see it either way. The evidence that
    it is Debug only is the source: `SettingsPages.swift` lines 371 and 410 and
    `SettingsScreen.swift` line 166 are all inside `#if DEBUG`.
- Load (1-minute average) at the start of each recording:
  - Toggle: 38.4.
  - Team editor: 20.2 and 17.8.
  - Sidebar: 12.0.

  Stills were taken at higher load, which does not affect them.
- Measurements are in points (pixels divided by 3), taken from AX frames and
  checked against the screenshots.

## Per item

| # | Item | Result | Evidence and measurement |
| --- | --- | --- | --- |
| 1 | Devices count matches page | **PASS** | Root `Devices 13` (`screens/root-dark-0.png`). The page lists 13 Mac rows: Mac Studio, MacBook Pro, Home MacBook, 2 x Aziz's MacBook Pro, mini 1-8 (`devices-dark-0/1.png`). One list (`SettingsDeviceList`) feeds both. |
| 2 | Color grid never behind keyboard | **PASS** | Custom opens the keyboard with the whole grid visible: the rows sit at y 259 and 313 pt, the keyboard top at about 487 pt, and the docked Done is hidden (`img/03-team-editor-flow.png` pane 2). Tapping Blue with the keyboard up recolors and keeps the keyboard (pane 3, `video/editor-color-with-keyboard-then-emoji-dark-402w.mp4`). |
| 3 | Notifications (override) | **PASS** | No push in this build. The "Allow notifications · Not set" row has the footer "For Chief's replies, while cmux is open or still running in the background." That copy matches `ChiefAlerts`, which posts local alerts only while the app runs. A second row has bell.slash and "Notifications from your Macs need the TestFlight build." (`notif-dark.png`). Tapping the row raises the real system prompt; Allow turns it to `On` (`notif-allowed-dark.png`) and the root value to `Chief only`. Push builds were checked from source only: kinds disabled at 40 % when Off, with the spec footer. |
| 4 | Transport (override) | **PASS** | Transport is a pushed page with WebRTC and WireGuard checkmark rows and the subtitle text from the spec, footer "Switching reconnects to your Macs." A "Developer" section with Relay only appears only in DEBUG (`transport-dark.png`). Production: see Setup. |
| 5 | Account | **PASS** | Header only: 64 pt initials, name, email, centered. One "Email code" sign-in row, and Delete Account. The Name and Email rows are gone (`account-light.png`). |
| 6 | Emoji first | **PASS** | Tapping the 56 x 56 pt well (`teamAppearance.character`, AX 173,413 56x56) opens the **emoji** keyboard with no predictive bar (`editor-dark-1-keyboard.png`). The hint is "Pick an emoji, or type a letter, number or symbol." Picking 🙈 replaces 🌵, dismisses the keyboard and brings Done back (`editor-dark-3-picked.png`). |
| 7 | Mock toggle | **PASS** | "Mock (layout only)" is on and disabled. The footer reads "Set by the launch environment." and "Dev test account: enter 42 as the email." (`root-dark-1.png`). |
| 8 | Largest text | **PASS at launch / FAIL live** | Launched at AX5 (`img/08-ax5-root-account-developer.png`, `notif-light-ax5.png`): icons scale (bell 31x34 pt, Face ID 32x32), titles do not break mid-word, and Notifications stacks "On" under the title. The email in the root card truncates as `aziz@e…ple.com` with no hyphen. **Fail:** changing the text size while the app runs leaves the Account name and "Email code" at Large while the email and header grow, so the email ends up larger than the name (`img/08-ax5-live-change-vs-relaunch.png`, left). Also, the envelope glyph in "Email code" stays at about 14 pt at AX5 while other row icons reach 32 pt. |
| 9 | Opaque editor sheet | **PASS** | Light editor: nothing of the page behind shows through (`editor-light-picked.png`). |
| 10 | Same-name tags | **Settings PASS / app FAIL** | Settings: capsule "3F2A" / "91C7" after the name; gap 6.5 pt (name ends x 218.5, capsule starts x 225). The 8 pt dot is centered on the title line (dot center y 181 = title center y 181). The dialog reads "Remove Aziz's MacBook Pro 91C7?" **Workspaces uses other formats for the same Macs** (`img/10-tag-formats-workspaces-vs-settings.png`): the filter menu subtitle is "Online · ID 3F2A" with no tag beside the name; the empty state and alerts say "Aziz's MacBook Pro (3F2A)" (`MacNameDisambiguation.displayName`); the accessibility value uses "(3F2A)". That is three spellings. Workspaces also computes tags over the active team's Macs (`WorkspacesList.swift:84`), while Settings uses every Mac on the account (`DevicesPage.swift:131`). A Mac whose namesake is in another team is tagged in Settings and untagged in Workspaces, and tag lengths can differ. |
| 11 | Root structure | **PASS** | Row height is 52 pt (all rows 370x52). The team row has no header. "Privacy & notifications" holds Notifications and Require Face ID. The Terminal/Composer section has no header. "Sign out" with "Sign out of cmux?". The version footer is text only. |
| 12 | Sidebar and setup | **PASS** | Setup lists one "Personal · Just you" (`setup-choose-space-dark.png`). Sidebar: team name x 68.6 pt; invite glyph center x 39 vs avatar center x 38; rows 60 pt; avatar 36 pt (`sidebar-open-dark.png`). Motion: button open settles in about 0.25 s; scrim close moves 4.615 to 4.955 s = 0.34 s, no overshoot (`video/sidebar-button-open-scrim-close-dark-402w.mp4`). |
| 13 | Swatches | **PASS** | 13 swatches in 7 columns (7 + 6), so no lone gray; 44 pt targets at a 50 pt pitch. The selected swatch has a ring (`editor-dark-0.png`). |
| 14 | Remove confirmation anchor (known open) | **FAIL, raised to Major** | The popover is anchored to the page, not the row. Its arrow always sits at y ≈ 378 pt, on top of "Aziz's MacBook Pro **3F2A**". Swiping **91C7** (row y 428-496) shows a "Remove … 91C7?" popover pointing at the 3F2A Mac. Swiping mini 4 (row y 700) points at the same 3F2A row (`img/14-remove-popover-points-at-wrong-row.png`). With same-name Macs this points at the wrong Mac. |
| - | Toggle tint and motion | **PASS** | Native iOS 27 Liquid Glass switch with a green `success` track (`img/04-toggle-60fps-dark.png`). Off to on: motion runs 2.92 to about 3.60 s. On to off: 6.07 to about 6.76 s. Frames are 16.7 ms apart (worst 18.3 ms, no dropped frames) (`video/toggle-relayonly-dark-402w.mp4`). |
| - | Dead controls | **PASS (checked)** | These all work: Allow notifications (system prompt), Transport rows, Devices swipe and Remove, Edit (shown only with a directory), the team "Color and icon" row, the editor's Close and Done, and the sidebar rows. External links were not opened. |

## New findings

- **A. Major: one Mac shows different presence on one screen.** Workspaces,
  Manaflow team (`ws-filter-personal-dark.png` is the Personal team; the
  Manaflow capture was overwritten, see below):
  - The filter menu showed "MacBook Pro · Last seen 1h ago".
  - The folded group row under it showed "MacBook Pro · Last seen 2h ago".
  - Settings → Devices shows the same Mac as "Last seen 2 hours ago".

  I saw this live and the AX tree recorded it, but the screenshot of the menu
  was overwritten by the Personal-team capture. Re-check it. Also use one
  presence format across surfaces ("2h ago" vs "2 hours ago").
- **B. Polish: Devices "Phones" section can be empty.** It has a header and
  the footer "Sign out to remove this iPhone.", but no rows
  (`devices-dark-1.png`, mock directory with no phones). Show "This iPhone" as
  a non-removable row, or hide the section when there are no phones.
- **C. Polish: team page title x is inconsistent.** "Color and icon" and the
  member name start at x 73 pt (28 pt avatar), but "Invite to team" starts at
  x 68 pt (`team-dark.png`). Align on one x.
- **D. Polish: editor preview hides behind the header.** With the keyboard
  up, the 72 pt preview scrolls under the header and only about 22 pt of it
  shows (`editor-dark-1-keyboard.png`, `editor-dark-2-blue-kbup.png`). The
  color change is visible, but the character in the preview is not. Pin the
  preview, or shrink it to 44 pt while the keyboard is up.

## Fix list (round 2)

1. **Item 14 (Major).** Anchor the Remove confirmation to the swiped row,
   or use a bottom action sheet with no arrow. It must never point at another
   row.
2. **Item 10 (Major).** Use one tag format and one tag scope everywhere:
   - Use `taggedName` ("Aziz's MacBook Pro 3F2A"), plus the capsule where a
     row shows a name, in the Workspaces filter, empty states, alerts and
     accessibility values.
   - Drop "ID 3F2A" and "(3F2A)".
   - Compute tags over the account's Macs in both places, so a Mac has the
     same tag everywhere.
3. **Item 8 live (Major).** Update the fonts that do not follow live Dynamic
   Type changes: the Account name and the `SettingsLabel` rows that use the
   fixed `theme.type` fonts. Scale the envelope glyph like the other row
   icons.
4. **A (Major).** One presence source and one format for a Mac across the
   filter menu, the folded group row and Devices.
5. **B, C, D (Polish)** as described above.

## Not covered

- Production Settings signed in: Production stops at the signed-out Welcome
  and needs a real account. Reviewed from source and the binary only.
- Push builds: the Notifications kinds and their disabled state.
- Require Face ID turned on, Delete Account progress, Couldn't remove alerts
  and Edit-mode delete.
- The sidebar's swipe gestures; only the button and the scrim were recorded.
- Light-mode motion.
