# Settings, sidebar and team editor: design spec

Designer pass, 2026-10-14. Scope: every Settings page (root, Account, Team,
Paired Macs with same-name ID tags and Remove, transport, Notifications,
Require Face ID, Terminal, Composer, Acknowledgements, Log out, Delete
Account), the hamburger sidebar (team switcher, Mac dots, Invite to team), and
the team appearance editor (Automatic / Custom character / None, emoji
keyboard).

## What was looked at

- Source: `origin/feat-cnx-ios` `d494906d46`. Files: `CmuxMobileSettings/SettingsScreen.swift`,
  `SettingsPages.swift`, `DevicesPage.swift`, `TeamAppearanceEditor.swift`,
  `CmuxMobileShell/TeamSidebar.swift`, `SidebarContainer.swift`, `CmuxMobileDesign/TeamRow.swift`,
  `Controls.swift`, `Theme.swift`, `CmuxMobileModel/Settings.swift`.
- Builds (simulator, `-jobs 4`, derived data in `/tmp`): Debug
  `dev.cmux.mobile.dsetDebug` and Production `dev.cmux.mobile.dsetProduction`, both
  1.1.0 (1).
- Simulator: one headless iPhone 17 Pro, iOS 27.0, 402 x 874 pt, 3x, named
  `cmux-mobile-design-settings` (deleted afterwards). Simulator.app never opened; input
  through `axe` HID. Never paired with a Mac; E2E rig not used.
- Debug was run in **mock (layout only)** mode (`CMUX_MOBILE_MOCK_AUTH=1`): sample user,
  four teams, same-name Macs, an 8-Mac team. Layout, copy and motion are
  real; counts, presence and members are sample data.
- Production: installed and launched; it stops at the signed-out Welcome
  (`screens/prod-launch.png`). Without an account, its Settings could only be
  reviewed from source (differences: no Developer section, no mock).
- Captured: every page in dark and light at Large (default) and AX5
  (`accessibility-extra-extra-extra-large`), scrolled through; switch
  animation at 60 fps; sidebar open/close by button, scrim tap, fast gesture
  and a slow, below-threshold gesture; team editor with the letter and emoji
  keyboards, None, Automatic, light, and AX5; Paired Macs swipe-to-Remove and
  its confirmation.
- References: `~/Downloads/cmux-native-references/` Claude 07/08 and 01,
  ChatGPT 03 and 13/14/15 (Codex settings), Grok 11/12/13; iOS 27 Settings
  conventions.

**Timing:** the 1-minute load average was 11.7 to 17.9 during both recordings
(127 earlier, during screenshots only). The recorder wrote frames 16.7 ms
apart during motion, so the timings below are good to about ±1 frame.

Coordinates are points on the 402 x 874 pt screen. Pixels were divided by 3.

## Images and videos

| File | Shows |
| --- | --- |
| `img/00-pages-<page>.png` | Each page: dark Large, light Large, dark AX5, light AX5 |
| `img/01-settings-root-vs-refs.png` | cmux root vs Claude, ChatGPT Codex, Grok settings |
| `img/02-sidebar-vs-refs.png` | cmux sidebar vs ChatGPT, Claude, Grok |
| `img/03-team-editor-keyboard.png` | Editor: Custom + letters, emoji keyboard, emoji picked, None, AX5 |
| `img/04-toggle-on-60fps-dark.png` | Off to on switch, every second frame at 60 fps (33 ms per cell) |
| `img/05-sidebar-open-button-30fps.png` | Hamburger opens the sidebar, 30 fps |
| `img/06-ax5.png` | AX5: root, Notifications, Account, Paired Macs |
| `img/07-paired-count-mismatch.png` | Root says "Paired Macs 2"; the page lists 13 Macs |
| `img/08-account-redundant.png` | Account repeats the name and email three times |
| `img/09-developer-mock-off.png` | Developer section: "Mock data" reads off while mock data is on |
| `img/10-paired-remove-swipe-confirm.png` | Trailing swipe Remove, then the confirmation popover |
| `video/toggle-off-on-dark-402w.mp4` | Wrap code switch: off, then on (60 fps) |
| `video/sidebar-button-scrim-gesture-dark-402w.mp4` | Button open, scrim close, swipe open, swipe close, slow drag that falls back |
| `screens/*.png` | All captures, 402 x 874 |

## What already matches the references (keep)

- **Switch tint and animation.** On tracks are `success` green in dark and
  light (`img/04`, `00-pages-terminal`); no white-on-white switch anywhere.
  The switch is the native iOS 27 Liquid Glass switch (`.toggleStyle(.switch)`
  under `CmuxMobileSwitchToggleStyle`): off to on moves in 0.40 s (5.53 to 5.93 s),
  settles by 0.67 s. Same as the system.
- **Swipe Remove** on Paired Macs is red with a trash glyph (not a white
  pill), trailing edge only. No leading swipe actions anywhere.
- **Sidebar motion** (`video/sidebar…`, `img/05`). Width 302 pt
  (0.75 x 402). Button open: 0.31 s to 99 %, no overshoot. Scrim close:
  0.34 s. Fast swipe open settles 0.30 s after release; fast swipe close
  0.39 s. A slow 100 pt drag (below the 40 % threshold) springs back closed.
  Matches ChatGPT's push-the-card drawer.
- **Nav stacks and back swipe**: every page is pushed in one
  `NavigationStack`; glass back circle; centered inline title (like Claude
  and Codex).
- **Same-name tags** exist: "Online · ID 3F2A" and "Last seen 3 days ago ·
  ID 91C7"; the remove dialog names "(91C7)".
- **Remove copy** says "turn on Settings → Mobile there" (user preference).
- **Team dots**: 7 pt dots, 4 pt apart, max five, then "+3" (Build Fleet, 8
  Macs); green online, gray offline.

## Priority list

| # | Level | Where | Change |
| --- | --- | --- | --- |
| 1 | Blocker | Paired Macs | Root row says "2"; the page lists 13 Macs (`img/07`). One source for both. |
| 2 | Blocker | Team editor | Keyboard and docked Done hide the whole Color grid and the selected swatch (`img/03` 1-3) |
| 3 | Major | Notifications | Non-push builds still ask for permission they cannot use; empty section with a footer (`00-pages-notifications`) |
| 4 | Major | Transport | Relay only is missing from the switch (Debug-only toggle); add it as a third choice |
| 5 | Major | Account | Name and email shown three times; Name and Email rows look editable but are dead (`img/08`) |
| 6 | Major | Team editor | Custom opens the letter keyboard; emoji is two taps away. Open on emoji; make the character large |
| 7 | Major | Developer | "Mock data" reads off while mock data is on; label must be "Mock (layout only)" (`img/09`) |
| 8 | Major | AX5 | Icons, avatars and the segmented control do not scale; trailing values squeeze titles into "noti-fica-tions" (`img/06`) |
| 9 | Major | Team editor | Translucent sheet shows the page behind it (light, `editor-te-light-large`) |
| 10 | Major | Paired Macs | Same-name Macs: tag only in the subtitle; the dialog says "(91C7)" but the row says "ID 91C7"; page title says Macs, page also holds phones |
| 11 | Polish | Root | Section structure: drop one-row headers, rename "Terminal" header, "Log out" to "Sign out" |
| 12 | Polish | Sidebar / setup | Two "Personal" spaces in the setup chooser; team row and header metrics |
| 13 | Polish | Team editor | 13 swatches leave a lone gray in row 3; predictive bar above a one-character field |
| 14 | Polish | Remove | Confirmation pops over the top of the screen, 200 pt above the swiped row |

## Details

### 1. Blocker: Paired Macs count disagrees with the page

- Evidence: `img/07`. Root: "Paired Macs 2" (the active team Manaflow has 2
  Macs). Page: 13 Macs (every team's Macs from the device directory) plus
  Phones. Code: `SettingsScreen` uses `store.accountMacCount ?? activeTeam.macs.count`;
  the page uses `directory.devices()`. In mock mode `accountMacCount` is nil.
- Should be: the root value is the number of rows the page shows under
  "Macs". Compute both from the same list. If it is not loaded yet, show no
  value (not a team count). No placeholder number.

### 2. Blocker: Team editor hides Color behind the keyboard

- Evidence: `img/03` panes 1-3. With Custom focused, the docked Done
  capsule sits at y 373-412 pt (just above the keyboard at 415 pt). The color
  grid starts at y 338 pt: the first row is cut through the middle and the
  second row, including the selected purple ring, is behind Done and the
  keyboard. With the emoji keyboard (taller, top at 361 pt) Done covers the
  "Color" header itself.
- Should be:
  - Order: preview 72 pt, Color grid, then Icon. Color is the main control and
    must never be behind the keyboard; Icon is the only control that raises it.
  - When the character field is focused, hide Done (`safeAreaInset` only when
    the keyboard is down) and put "Done" in the keyboard's return key (it is
    already `.submitLabel(.done)`); tapping it dismisses the keyboard and the
    docked capsule comes back.
  - Or scroll the focused field to 16 pt above the keyboard and keep the grid
    reachable by scrolling; never overlap a docked button with the grid.

### 3. Major: Notifications in builds without push

- Evidence: `00-pages-notifications`. Production and Debug show "Allow
  notifications · Not set" as a tappable button that calls
  `requestAuthorization`, then an empty section whose footer says "This build
  can't receive notifications from your Macs. The TestFlight build can."
- Should be (non-push builds, `BuildCapabilities.current.push == false`):
  - No "Allow notifications" row and no permission prompt (it would ask for
    something that cannot happen).
  - One non-interactive row: bell.slash icon, title "Not available in this
    build", no chevron. Footer: "Notifications from your Macs need the
    TestFlight build of cmux."
  - Root Settings row: "Notifications" with trailing value "Unavailable"
    (label2), still pushes the page.
- Push builds stay as they are, plus: the trailing value reads "On", "Off" or
  "Not set" and the kinds section is disabled (40 % opacity) while the system
  setting is Off, with footer "Turn on notifications in iOS Settings to
  choose what you get."

### 4. Major: Transport switch is missing Relay only

- Evidence: `00-pages-root`, `09`. Connection → Transport is a 2-item menu
  picker (WebRTC, WireGuard). "Relay only (simulate distant network)" is a
  separate switch in the DEBUG-only Developer section, so Production has no
  relay-only choice.
- Should be: Transport row pushes a page (not a menu) titled "Transport",
  inset grouped, checkmark list, `label` tint:
  - "WebRTC" — subtitle "Direct when possible, relay otherwise. Recommended."
  - "WireGuard" — subtitle "Encrypted tunnel to your Mac, relay when needed."
  - "Relay only" — subtitle "Always through the cmux relay. Slower; use it
    when direct connections fail."
  - Footer: "Switching reconnects to your Macs." When the relay is
    unavailable, "Relay only" is disabled with subtitle "Relay unavailable".
  - Root row trailing value: the chosen title. Remove the Developer switch.
  If relay only must stay a WebRTC/WireGuard modifier, make it a second
  section on the same page with one green switch "Relay only", not a
  Developer toggle.

### 5. Major: Account page repeats itself

- Evidence: `img/08`. Header card (56 pt initials, name, email), then a
  "Name" section with the name, an "Email" section with the email, then
  "Sign-in methods: Email code · aziz@example.com". The Name and Email rows
  are styled as rows but do nothing.
- Should be (Apple Account and Claude profile): header card only (64 pt
  initials centered, name 22 pt semibold, email 15 pt label2, centered, no
  row background); "Sign-in methods" section: one row per method with its
  brand glyph (Google, GitHub, Apple, envelope), title, and no repeated
  email unless it differs from the account email; "Delete Account" section
  as is. Remove the Name and Email sections. If the name is editable later,
  make it a real row with a chevron.

### 6. Major: Emoji is hard to reach in the team editor

- Evidence: `img/03`, `editor-te-11`, `editor-te-16`. Custom opens the
  letter keyboard with a predictive bar ("t", "the", "to"). Emoji takes the
  globe/emoji key; the system then shows its skin-tone tip. After picking 🙈
  the field shows it at about 20 pt in a 160 pt-wide trailing text field;
  the preview updates correctly; a second pick replaces the first (good).
- Should be:
  - The field opens on the emoji keyboard (`UITextField` subclass whose
    `textInputMode` returns the emoji mode); the user can still switch to
    ABC for a letter. Copy: "Pick an emoji, or type a letter, number or
    symbol."
  - Replace the "Character / Type one" row with a centered 56 x 56 pt
    tappable well under the segmented control showing the current
    character at 34 pt (empty: dashed 1 pt `separator` rounded rect with a
    face.smiling glyph). No placeholder text that reads like an instruction
    to type a word.
  - Hide the predictive bar (`.textContentType(.none)`, spellChecking off,
    `UITextInputAssistantItem` groups empty).

### 7. Major: Developer section mock toggle

- Evidence: `img/09`. Launched with `CMUX_MOBILE_MOCK_AUTH=1`, Settings shows "Mock
  data" switch off and "Service: Mock". The footer is 8 lines.
- Should be: title "Mock (layout only)"; the switch is on whenever mock data
  is in use (stored key or the environment), disabled with footer "Set by the
  launch environment" when the environment forces it. Shorten the footer to:
  "Sample user, teams and Macs for checking layout. Applies at next launch."
  Put the relay text on the transport page (item 4) and the "42" test
  account hint in its own one-line footer.

### 8. Major: Largest text size

- Evidence: `img/06`, all `*-ax5-*` screens.
  - Row icons stay 17 pt and team avatars 28 pt while titles grow to ~44 pt;
    the icon column floats mid-row. Use `@ScaledMetric` for the icon size and
    the 22 pt icon frame, capped at 2x (34 pt / 44 pt).
  - Notifications: "Allow noti-fica-tions" broken into four hyphenated lines
    beside "Not set". Under accessibility sizes, stack the trailing value
    under the title (`ViewThatFits` or `dynamicTypeSize.isAccessibilitySize`
    → `VStack(alignment: .leading)`), as iOS Settings does.
  - Account header: "aziz@ex-ample.com" hyphenated. Emails must never
    hyphenate: `.lineLimit(1)` + `.minimumScaleFactor(0.6)` or wrap at
    `@` / `.` only (`.truncationMode(.middle)` as fallback).
  - Team editor: the segmented control stays 13 pt and Done covers the
    grid; the sheet's 640 pt detent should become `.large` only at
    accessibility sizes.

### 9. Major: Team editor sheet is see-through

- Evidence: `editor-te-light-large.png`: the "Color and icon" row and section
  text of the page behind show through the sheet between the Icon and Color
  sections.
- Should be: opaque `bgGrouped` (light) / `surface` (dark) sheet background
  (`.presentationBackground(theme.colors.bgGrouped)`), as Claude's and the
  system's form sheets.

### 10. Major: Paired Macs naming and same-name tags

- Evidence: `00-pages-pairedMacs`, `img/10`.
  - Title "Paired Macs" while the page also lists Phones. Rename the page
    and row "Devices" with sections "Macs" and "Phones", or move Phones to
    Account. Recommended: "Devices".
  - Same-name Macs differ only in the second line ("Online · ID 3F2A").
    Show the tag next to the name: title "Aziz's MacBook Pro" followed by a
    capsule "3F2A" (11 pt monospaced semibold, label2 on fillSelected,
    4 x 2 pt padding, 6 pt corner radius, 6 pt gap). Subtitle keeps presence
    and "Added Oct 3". Use the same tag text everywhere: the dialog title
    becomes "Remove Aziz's MacBook Pro 3F2A?", not "(91C7)" vs "ID 91C7".
  - Status dot: 8 pt in a 22 pt frame, vertically centered on the title
    line (not the two-line block), so it reads with the name.

### 11. Polish: Root structure and wording

- `img/01`. cmux root: Account card, then 7 headed sections (Team,
  Connection, Terminal, Appearance, Notifications, Security, About) plus
  Log out; row pitch 54 pt (Claude 47, Codex 49, Grok 49, iOS 27 Settings
  52 with icons).
  - Row height 52 pt (`settingsRowHeight`).
  - Remove one-row section headers: "Team" (the team row with avatar reads
    on its own) and "Notifications" (merge into the Security section as
    "Notifications" + "Require Face ID", header "Privacy & notifications"
    — or no header).
  - Header "Terminal" contains rows "Terminal" and "Composer": rename the
    header "Input and display" or drop it.
  - "Log out" → "Sign out" (onboarding and the setup footer say "Sign out";
    the dialog: "Sign out of cmux?" / "Sign out").
  - Version footer mark renders as a bare chevron glyph at 16 pt; use the
    app icon mark at 20 pt or text only.

### 12. Polish: Sidebar

- `img/02`, `screens/sidebar-open-dark.png`. Matches ChatGPT/Claude: title
  left (cmux, 22 pt semibold), glass "+" circle 44 pt at x 238-282, team
  rows 60 pt with a 36 pt avatar, selected `fillSelected` with 14 pt radius
  and 10 pt inset, "Invite to team" as the last row.
  - The setup chooser lists "Personal — Just you" and a team also named
    "Personal" (🌵) (`settings-root-dark.png`); the sidebar shows only the
    team. Show the personal space the same way in both, and never two
    identical names without a tag.
  - "Invite to team" glyph (17 pt) reads left-heavy against the 36 pt
    avatars above; center it in the 36 pt avatar column and match the
    team-name x (both should start at 68 pt).
  - Section label "Teams" at 13 pt label2 is fine; drop it when there is one
    team.

### 13. Polish: Team editor details

- 13 swatches in 6 columns leave a single gray swatch on row 3
  (`editor-te-7`). Use 12 swatches (6 x 2) or 7 columns of 40 pt (7 x 40 +
  6 x 10 = 340 pt fits the 362 pt width).
- The selected ring is 3 pt `label` with a 3 pt gap: good. Keep.
- Segmented control: when Custom is selected with an empty field, the
  preview shows Automatic's letter; show the empty well instead so the
  user knows nothing is chosen yet.

### 14. Polish: Remove confirmation position

- `img/10`: the confirmation pops out of the top bar at y 62-375 pt while
  the swiped row is at y 466 pt. Anchor the dialog to the row
  (`confirmationDialog` on the row, or an action sheet from the bottom), so
  the eye does not jump 200 pt.

## Not captured

- Production Settings signed in (needs a real account; Production stops at
  Welcome). Push-build Notifications (TestFlight only), Require Face ID
  turning on (would lock the simulator app behind passcode), Delete Account
  progress and error states, the Team page members loading/failed states,
  and live "Couldn't remove" alerts. Reviewed from source only.
- Light-mode switch and sidebar recordings (dark only; screenshots show the
  light switches green).
- The sidebar's long-press context menu and the "+" menu alerts (Create
  team, Join with invite link).
