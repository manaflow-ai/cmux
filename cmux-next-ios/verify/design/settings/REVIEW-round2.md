# Settings round 2: designer review

Fresh reviewer pass, 2026-10-14. I checked every item in `SPEC.md` and every
round 1 failure against my own builds and captures in `round2-review/`. The
implementer's `round2/` captures are claims, and I did not use them as
evidence. The orchestrator overrides apply:

- Relay only exists only in Debug and Demo.
- The Notifications permission row stays, and its copy must be literally true.
- Known limits:
  - SwiftUI menus can't draw the tag capsule, so the Workspaces filter menu
    shows the tag as text, for example "Aziz's MacBook Pro 3F2A".
  - Remove opens a centered alert, with no arrow.

**Verdict: NOT SIGNED OFF.** One item fails:

- **F (Major, regression):** at the largest text size (AX5), the tag capsule
  on the Devices page breaks the Mac name mid-word ("Mac-Book").

Every round 1 failure (14, 10, 8-live, A, B, C, D) and items 1 to 13 pass. Two
polish notes (G, H) and one note on "Last seen just now" are below. None of
them blocks sign-off.

## Setup

- Source: `origin/feat-cnx-ios` `d988909f92a6`, built in a separate review
  worktree that was removed afterwards. I copied in `CmuxMobileLinkFFI.xcframework`, ran
  `xcodegen`, and built for the simulator with `-jobs 4` and derived data in
  `/tmp/cmux-mobile-settings-review2-dd`:
  - Debug: `dev.cmux.mobile.srev2Debug`, built with `CMUX_MOBILE_TAG=.srev2Debug`.
  - Production: `dev.cmux.mobile.prod`.
- Simulator: one headless iPhone 17 Pro on iOS 27.0, 402 x 874 pt at 3x, named
  `cmux-mobile-settings-review2` (deleted afterwards). Input went through `axe`. The E2E
  rig was not used and the app was never paired with a Mac.
- **Mock (layout only).** Debug ran with `CMUX_MOBILE_MOCK_AUTH=1`. The user, teams,
  Macs, presence and times are sample data. Layout, copy and motion are real.
- Production:
  - `scripts/check-production-binary.sh` reports `ok` (2 binaries, 29 strings
    checked).
  - `strings` finds none of "Mock (layout", "layout only", "simulate distant",
    "ID 3F2A" or "Relay only".
  - The only "Developer" hits are the type name `DeveloperOptions` and an SDK
    error string.
  - Relay only sits inside `#if DEBUG` (`SettingsPages.swift` 420-434). The
    Demo configuration keeps DEBUG (`project.yml`), so Debug and Demo have it
    and Production and TestFlight do not. This meets the override.
  - Production stops at the signed-out Welcome (`screens/prod-launch.png`).
- Load (1-minute average) at the start of each recording:
  - Editor recording: 20.8 at the start, 21.3 at the end.
  - Sidebar recording: 25.7.

  Both are under the 40 limit. Stills were taken at 20 to 30.
- Measurements are in points, taken from AX frames and checked against the
  screenshots. `screens/` images were downscaled to 402 px wide (1 px = 1 pt)
  to keep the folder small.

## Per item

| # | Item | Result | Evidence and measurement |
| --- | --- | --- | --- |
| 1 | Devices count matches page | **PASS** | Root `Devices 13` (`screens/root-dark-0.png`). The page lists 13 Mac rows: Mac Studio, MacBook Pro, Home MacBook, 2 x Aziz's MacBook Pro, mini 1-8 (`devices-dark-0.png`, `B-devices-bottom.png`). |
| 2 | Color grid never behind keyboard | **PASS** | With the emoji keyboard up (top at y 486), the grid rows sit at y 197-241 and 251-295 and the docked Done is hidden (`img/D-editor-keyboard.png` pane 2). Tapping Blue with the keyboard up recolors the preview and the ring moves (pane 3). |
| 3 | Notifications (override) | **PASS** | Row "Allow notifications · Not set". Footer: "For Chief's replies, while cmux is open or still running in the background." A non-interactive bell.slash row: "Notifications from your Macs need the TestFlight build." (`notif-dark.png`). Root value "Not set" under "Privacy & notifications". The copy is literally true for a non-push build: Chief's alerts are local and only fire while the app runs. |
| 4 | Transport (override) | **PASS** | Pushed page with WebRTC and WireGuard checkmark rows, the spec subtitles, and the footer "Switching reconnects to your Macs." The Developer → Relay only switch appears in DEBUG only. Production: see Setup (`transport-dark.png`). |
| 5 | Account | **PASS** | Header only: 64 pt initials, name, email. One "Email code" row, then Delete Account (`8-account-large.png`). |
| 6 | Emoji first | **PASS** | Tapping the 56 x 56 well opens the **emoji** keyboard ("Search Emoji", Frequently used) with no predictive bar. Picking 🙈 replaces 🌵, dismisses the keyboard and brings Done back at y 780 (`editor-dark-picked.png`, `video/editor-emoji-keyboard-preview-pinned-dark-402w.mp4`). |
| 7 | Mock toggle | **PASS** | "Mock (layout only)" is on and disabled. Footers: "Set by the launch environment." and "Dev test account: enter 42 as the email." (`root-dark-1.png`). |
| 8 | Largest text, live change (round 1 fail) | **PASS** for Account and root; **see F** for Devices | Account at Large, then switched to AX5 while running (`img/08-live-type-change.png`). The name grows to 67 pt line height, above the 49 pt email, so the name is again larger than the email. "Email code" grows to 63 pt and the envelope from 20 x 14 to 39 x 28 pt. Root at AX5 live: icons 35 pt, avatar 56 pt, no mid-word breaks, and the email truncates in the middle (`aziz@e…ple.com`). |
| 9 | Opaque editor sheet | **PASS** | Nothing of the page behind shows through (`editor-dark-0.png`). |
| 10 | One tag, one scope (round 1 fail) | **PASS** (with the known menu limit) | Personal team (`img/10-one-tag-workspaces-and-devices.png`). The empty state reads "New workspaces open right away on Aziz's MacBook Pro 3F2A." The filter menu reads "Aziz's MacBook Pro 3F2A · Online" and "Aziz's MacBook Pro 91C7 · Last seen 3d ago". Devices shows the name plus capsules "3F2A" / "91C7". The gap from the name end (x 219) to the capsule (x 225) is 6 pt. "ID 3F2A" and "(3F2A)" are gone from the source and the binary. Scope: Workspaces tags over `store.teams.flatMap(\.macs)` (`WorkspacesList.swift:95`), and Devices over the same list plus any directory-only Macs (see H). |
| 11 | Root structure | **PASS** | Rows are 52 pt. The team row has no header. "Privacy & notifications" holds Notifications and Require Face ID. The Terminal/Composer section has no header. "Sign out". |
| 12 | Sidebar | **PASS** | Rows 60 pt, avatar 36 pt, the "+" circle 44 pt at x 238, Invite glyph and team name at x 68 (`sidebar-open-dark.png`). Motion, from frame differences at 60 fps (`video/sidebar-button-scrim-swipe-dark-402w.mp4`): <ul><li>Button open: about 0.43 s, including the tap highlight.</li><li>Scrim close: 0.42 s.</li><li>Fast swipe open: a 0.12 s drag, then the sidebar settles in 0.30 s.</li><li>Swipe close: a 0.15 s drag, then it settles in 0.33 s.</li></ul> No overshoot. |
| 13 | Swatches | **PASS** | 13 swatches in rows of 7 and 6. Targets are 44 pt at a 50 pt pitch, with a ring on the selected swatch (`editor-dark-0.png`). |
| 14 | Remove confirmation (round 1 fail) | **PASS** (known limit: centered alert) | Swipes on 91C7, 3F2A and mini 4 open a centered alert with no arrow, and each one names the swiped Mac: "Remove Aziz's MacBook Pro 91C7?", "… 3F2A?" and "Remove mini 4?". The message also changes with presence (online vs offline) (`img/14-remove-alert-per-row.png`). Nothing points at the wrong row. |
| A | One presence format (round 1 fail) | **PASS** | Manaflow's MacBook Pro shows "Last seen 2h ago" in the filter menu, the folded group row and Devices (`img/A-last-seen-three-surfaces.png`). All three use `RelativeStamp.presence`. |
| B | Empty Phones section | **PASS** | No Phones header or footer when there are no phones. The page ends with the Macs footer (`B-devices-bottom.png`). |
| C | Team page title x | **PASS** | "Color and icon", "Aziz Albahar" and "Invite to team" all start at x 74 (`C-team-dark.png`). The invite glyph is centered at x 48.7 against the avatar center at x 46, which is 2.7 pt off and acceptable. |
| D | Editor preview with keyboard | **PASS** | The preview is pinned and shrinks from 72 to 48 pt (y 144-192) while the keyboard is up. The color and the character stay visible (`img/D-editor-keyboard.png`). The keyboard and shrink motion take 0.43 s (3.617 to 4.05 s), with a change in every 16.7 ms frame. |
| - | Toggle tint and motion | **PASS (unchanged)** | The root switches are green. The switch code did not change since round 1, which measured its motion. |

## Failing

- **F. Major (regression of item 8): the tag capsule breaks the Mac name at
  AX5.**
  - Evidence: `img/F-devices-ax5-tag-breaks-name.png`, Devices in light mode at
    AX5. Each "Aziz's MacBook Pro" row shows one word per line, with
    "MacBook" hyphenated as "Mac-/Book". The capsule beside the name is now
    99 x 48 pt.
  - Cause: round 2 moved the capsule to `MacNameTag`, which uses `.caption2`
    with `.fixedSize()`. The capsule scales with Dynamic Type and claims its
    full width, which squeezes the name in the `HStack`.
  - Fix: at accessibility sizes (`dynamicTypeSize.isAccessibilitySize`), put
    the capsule on its own line under the name, before the presence line. Draw
    the name with `UnbrokenText` (as other rows do) so it never hyphenates.
    Cap the capsule font at about 2x its Large size.

## Polish notes (do not block)

- **G. Invite on the personal space.**
  - The Team page and the sidebar offer "Invite to team" while the personal
    space ("Personal", "Just you") is selected (`C-team-dark.png`).
  - In live mode the action shows the toast "Create a team to invite people"
    (`ShellModel.invite`), so the row offers something it then refuses.
  - Fix: hide the row for `personal-` teams, or retitle it "Create a team".
- **H. Tag scope edge.**
  - Devices adds directory-only Macs to the tag scope
    (`MacNameDisambiguation(account:extra:)`). Workspaces does not.
  - A Mac that the device service lists but that no team contains (for
    example, signed in to a team you left) can make Devices tag a name that
    Workspaces leaves untagged, or lengthen a tag.
  - It is rare and invisible in the mock data. Either use the same input on
    both surfaces, or drop `extra`.
- **Mock-only observation, out of scope:** picking "Personal" in the setup
  chooser left Manaflow selected. `pickPersonal` relies on the live
  coordinator, which mock mode does not run. Re-check this on a live build.

## "Last seen just now" for up to about 2 minutes

`RelativeStamp.string` floors both times to the whole minute and returns
"now" while they are fewer than 120 s apart. As a result:

- **What the rule shows:**
  - "Last seen just now" covers 0 to 119 s of real time.
  - The label never says "1m ago".
  - The next value is "2m ago", which can appear at 61 s. At 10:02:00, a Mac
    last seen at 10:01:00 says "just now" and one seen at 10:00:59 says "2m
    ago".
  - Workspace row stamps follow the same rule ("now" up to about 2 min, then
    "2m").
- **Judgment: acceptable, not blocking.**
  - "Just now" is vague by nature, and up to 2 minutes is within what iOS apps
    use for presence. No surface claims a precise time.
  - The surfaces agree, and they did not in round 1.
  - It is not fully truthful at the edge: "2m ago" for a 61-second gap
    overstates by almost a minute, and the missing "1m" is noticeable on a
    workspace that just went quiet.
- **Recommended (polish):**
  - Get agreement from one shared `now` that ticks on the minute and is passed
    to every surface, as `MacFilterMemo` already does. Then count real elapsed
    seconds: "just now" under 60 s, "1m" from 60 to 119 s, and so on.
  - The Devices page calls `RelativeStamp()` with `Date()` when it renders and
    does not tick, so an open Devices page keeps "just now" until something
    else redraws it.

## Fix list (round 3)

1. **F (Major):** stack the tag capsule under the name at accessibility sizes,
   draw the name unbroken, and cap the capsule's scale. Capture Devices at AX5
   with a same-name pair in light and dark.
2. **G (Polish):** no "Invite to team" on the personal space, in the Team page
   or the sidebar.
3. **H (Polish):** use one tag scope input for Devices and Workspaces.
4. **Last seen (Polish):** use a shared minute-tick `now` and exact elapsed
   minutes, so "1m" exists and "2m" never appears for 61 s. Refresh Devices on
   the same tick.

## Not covered

- Production Settings signed in: Production stops at Welcome without a real
  account. Reviewed from source and the binary only.
- Push builds (the Notifications kinds and their disabled state), Require Face
  ID turned on, Delete Account progress, Couldn't remove alerts, and Edit-mode
  delete.
- A Workspaces folded row with a tag capsule: the sample workspaces sit only on
  uniquely named Macs. That row uses the same `MacNameTag`, so finding F likely
  applies there at AX5 too.
- Light-mode motion.
