# Settings round 3: designer review

Fresh reviewer pass, 2026-10-14. I re-checked every item in `SPEC.md`, the
round 1 and round 2 failures, and the round 3 changes against my own builds
and captures in `round3-review/`. The implementer's `round3/` images are
claims, and I did not use them as evidence. Overrides as in round 2: Relay
only in Debug and Demo only; the Notifications permission row stays with
literally true copy; the Workspaces filter menu spells the tag as text; Remove
is a centered alert.

**Verdict: SIGN-OFF.** No item fails. One new polish note (P1) and two small
notes are below; none of them blocks.

## Setup

- Source: `origin/feat-cnx-ios` `92e04eaa5d07`, merged into
  `feat-cnx-ios-design-settings`. `CmuxMobileLinkFFI.xcframework` present, `xcodegen`,
  simulator builds with `-jobs 4`, derived data `/tmp/cmux-mobile-settings-review3b-dd`:
  - Debug `dev.cmux.mobile.srev3Debug` (`CMUX_MOBILE_TAG=.srev3Debug`).
  - Production `dev.cmux.mobile.prod`.
- One headless iPhone 17 Pro, iOS 27.0, 402 x 874 pt, named
  `cmux-mobile-settings-review3b`, deleted at the end. Input through `axe`. No E2E rig;
  never paired with a Mac.
- **Mock (layout only).** Debug ran with `CMUX_MOBILE_MOCK_AUTH=1`: user, teams,
  Macs, presence and times are sample data; layout, copy and motion are real.
- Production: `scripts/check-production-binary.sh` reports `ok` (2 binaries,
  29 strings). `strings` finds no "Mock (layout", "layout only", "simulate
  distant", "ID 3F2A" or "Relay only". It stops at the signed-out Welcome
  (`screens/prod-launch.png`).
- Load (1-minute average):
  - Sidebar recording: 27.4 at the start, 25.9 at the end.
  - Last-seen clock recording: 78 at the start (another job), 18 at the end.
    That recording measures minute ticks, not motion, so the load does not
    affect it; its evidence is the AX poll log, not frame timing.
- Measurements are points from AX frames, checked against the screenshots.
  `screens/` are downscaled to 402 px wide (1 px = 1 pt).

## Round 3 changes

| # | Item | Result | Evidence and measurement |
| --- | --- | --- | --- |
| F | Tag under the name at AX5, Devices (round 2 fail) | **PASS** | `img/F-devices-large-vs-ax5-tag-under-name.png`. **Large:** the name is 68-219 and the capsule text starts at 229, so the capsule edge is at 225 (6 pt gap). **AX5, live change, dark and light:** "Aziz's / MacBook Pro" wraps between words, and "MacBook Pro" is one line at 298.7 pt wide. Line height is 63 pt, the same as the unshrunk "mini 1", so the name is not scaled down. No hyphen. Capsule "91C7" is on its own line (text 54.7 x 26.3 at x 72, capped at 22 pt), then "Last seen / 3d ago". Same for 3F2A / Online. |
| F | Folded Workspaces row at AX5 | **PASS** | `img/F-workspaces-folded-row-large-vs-ax5.png`, Personal. **Large:** one line, "Aziz's MacBook Pro" (41-166), capsule 91C7 (text at 176), then "· Last seen 3d ago" (213-328). **AX5, dark and light:** "Aziz's / MacBook / Pro" (word breaks only, column 199 pt), capsule 91C7, then "Last seen / 3d ago". The VoiceOver label is "Aziz's MacBook Pro 91C7 · Last seen 3d ago". |
| LS | Shared MinuteClock, exact elapsed time | **PASS** | `LS-poll-log.txt`, `img/LS-row-stamps-before-after-0653-tick.png`, `video/LS-row-stamp-1m-to-2m-at-minute-tick-402w.mp4`. The app launched at 06:51:55.9, so the mock `cmux` workspace was last active at about 06:50:56. I polled its row stamp about every 3 s for 3.5 min: <ul><li>06:52:07 to 06:53:03: "1m". The 06:52:00 tick is 64 s after.</li><li>06:53:06: "2m" (124 s at the 06:53:00 tick).</li><li>06:54:04: "3m".</li><li>06:55:03: "4m".</li></ul> "1m" now exists, and "2m" never shows before 120 s. Every other row stepped on the same tick (cmux.com 3m to 4m, cmux-next-ios 6m to 7m, fleet 12m to 13m, ghostty 25m to 26m). Source: no `RelativeStamp()` with an implicit `Date()` is left. Devices, the filter, the folded row, the empty state and the row stamps all read `MinuteClock.shared.now`. Devices reads it in `body`, so it redraws on the tick (source only; the mock data has no Mac that crosses a boundary while I watched). |
| LS | One "Last seen" text on every surface | **PASS** | Manaflow's MacBook Pro reads "Last seen 2h ago" on Devices, in the filter menu ("MacBook Pro, Last seen 2h ago") and on the folded row ("MacBook Pro · Last seen 2h ago") (`img/LS-last-seen-2h-devices-filter-folded.png`). |
| G | No Invite on Personal: team page, sidebar, long-press | **PASS** | `img/G-invite-hidden-on-personal-only.png`, left to right: <ul><li>Manaflow sidebar: Invite at y 336.</li><li>Personal sidebar: the list ends at Build Fleet, with no Invite.</li><li>Long-press Personal: "Change color and icon" and "Copy team name" only.</li><li>Long-press Manaflow: the same two plus "Invite to team".</li><li>Personal team page: Color and icon, then Members (you), with no Invite section.</li></ul> The Manaflow team page still has Invite at y 504 (`editor-dark-0.png` background). |
| H | One tag scope | **PASS** | `MacNameDisambiguation(account:)` lost `extra`. Devices and Workspaces both tag over `MacNameDisambiguation.scope(store.teams)`. The test `aMacOnlyTheServiceListsChangesNoTag` covers a Mac that only the device service lists (source). |

## SPEC items and earlier failures (re-checked)

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Devices count | **PASS** | Root "Devices 13". The page lists 13 Macs: Mac Studio, MacBook Pro, Home MacBook, 2 x Aziz's MacBook Pro, mini 1-8 (`F-devices-dark-large-0.png`, `devices-dark-bottom.png`). |
| 2 / D | Color grid never behind keyboard; preview pinned | **PASS** (see P1) | Custom with the keyboard up: preview at y 144-192, grid rows at y 213-257 and 267-311, Done hidden (`editor-dark-custom.png`). After a pick, the keyboard goes down, the preview is 72 pt and Done is back at y 780 (`editor-dark-picked.png`). |
| 3 | Notifications (override) | **PASS** | Root "Notifications · Not set" under "Privacy & notifications" (`root-dark-1.png`). Unchanged since round 2. |
| 4 | Transport (override) | **PASS** | Pushed page: WebRTC and WireGuard with the spec subtitles, and "Switching reconnects to your Macs." A Debug-only "Developer" section holds "Relay only" (`transport-dark.png`). It is absent from Production (Setup). |
| 5 | Account | **PASS** | Header only (64 pt initials), "Email code", then Delete Account (`account-dark.png`). |
| 6 | Emoji first | **PASS** | Custom opens the emoji keyboard ("Search Emoji"), with no predictive bar. The empty well is dashed with a face glyph, and the preview is empty, not the letter (round 1 item 13). Picking ✌️ fills the preview and closes the keyboard. |
| 7 | Mock toggle | **PASS** | "Mock (layout only)" is on and disabled. Footers: "Set by the launch environment." and "Dev test account: enter 42 as the email." (`root-dark-1.png`). |
| 8 | AX5 | **PASS** | Root: 56 pt avatar, names wrap between words, and the email truncates in the middle ("aziz@e…ple.com") (`root-dark-ax5-0.png`). Account: name 67 pt line height, email 49 pt (`account-dark-ax5.png`). Devices and folded row: see F. |
| 9 | Opaque sheet | **PASS** | Nothing of the page behind shows through (`editor-dark-*`). |
| 10 | One tag, everywhere | **PASS** | Devices capsules 3F2A and 91C7. The alert reads "Remove Aziz's MacBook Pro 91C7?" with the same tag. |
| 11 | Root structure | **PASS** | 52 pt rows. No header on the team row. The Terminal/Composer section has no header. "Sign out" (`root-dark-0/1/2.png`). |
| 12 | Sidebar | **PASS** | 60 pt rows, 36 pt avatars, "+" 44 pt at x 238, Invite title at x 68. Motion from frame differences (`video/sidebar-button-scrim-swipe-dark-402w.mp4`): button open 0.45 s (with the tap highlight), scrim close 0.45 s, fast swipe open 0.38 s (with a 0.15 s drag), swipe close 0.40 s (with the drag). No overshoot; round 2 measured 0.42-0.43 s. |
| 13 | Swatches | **PASS** | 13 swatches in rows of 7 and 6, 44 pt targets at a 50 pt pitch. |
| 14 | Remove (override) | **PASS** | Swiping 91C7 shows a red Remove action, then a centered alert: "Remove Aziz's MacBook Pro 91C7?", Cancel / Remove (`14-remove-alert-91c7.png`). |
| - | Switch tint | **PASS** | Green on tracks in the root (Haptic feedback, Mock). |

## Notes (do not block)

- **P1. Polish: "Color" header clipped with the keyboard up.**
  - Evidence: `img/P1-editor-color-header-clipped-keyboard-up.png`, left pane.
    With Custom focused, the "Color" header text (y 189-205) is cut through its
    top half by the pinned preview's band at about y 195. With the keyboard
    down it is whole at y 236 (right pane).
  - Fix: stop the keyboard auto-scroll with the header fully below the
    preview band, or fade the content under the band (a scroll edge effect)
    instead of a hard cut.
- **VoiceOver time can disagree with the visible stamp.** The row's spoken
  label uses `RelativeDateTimeFormatter` against `Date()`
  (`WorkspacesList.swift:886`), not the shared clock. For up to a minute, a row
  can show "4m" while VoiceOver says "5 minutes ago". Fix: format against
  `MinuteClock.shared.now`.
- **Device status dot at AX5.** The dot stays 8 pt next to 63 pt type
  (`F-devices-dark-ax5-*`). It stays centered on the first line, so it still
  reads. It could scale with `@ScaledMetric`, capped at 2x.
- Mock-only (carried over): picking "Personal" in the setup chooser left
  Manaflow selected. Re-check on a live build.

## Fix list

None required for sign-off. Optional: P1, the VoiceOver time, and the dot
scale.

## Not covered

- Production Settings signed in (stops at Welcome), push-build
  Notifications, Require Face ID on, Delete Account progress, Couldn't remove
  alerts, and live invite toasts. Reviewed from source and the binary only.
- Devices redrawing on a tick while open: the mock data has no Mac that crosses
  a minute boundary. Covered from source and by the row-stamp recording, which
  runs on the same clock.
- Light-mode motion.
