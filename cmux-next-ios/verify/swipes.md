# Swipe actions app-wide: verification

Branch `feat-cnx-ios-swipes`, 2026-10-13. User feedback: "the delete swipe action button looks wrong
in dark mode" and "left swipe actions are weird since we have a hamburger menu for teams".

## The rule (SPEC 3.3, swipe rules)

- No list has leading-edge (swipe right) actions. A rightward pan on a tab root opens the team
  drawer, so leading actions moved to the trailing edge, the context menu, or both.
- Custom swipe rows begin their pan only for a leftward drag (or to close open actions), so a
  rightward pan falls through to the drawer pan.
- At most three trailing actions, outermost first; a full swipe runs the outermost and never grants
  a permission.
- Destructive actions draw the system destructive red. Non-destructive actions use UIKit semantic
  system colors (`systemBlue`, `systemIndigo`, `systemPurple`, `systemGreen`, `systemOrange`,
  `systemGray`), white icon over a short label, as in Mail and Messages.

The Workspaces list is out of scope (owned by `feat-cnx-ios-wslist2`).

## Root cause of the dark-mode Delete

The shell applies `.tint(theme.colors.label.color)` to the whole `TabView` (RootView). A `List`
swipe button with `role: .destructive` and no tint of its own inherits that tint, so Home's Delete
drew as a white capsule with a white icon in dark mode (`before-home-trailing-dark.png`). Delete now
clears the tint with `.tint(nil)` so the role draws the system red.

## Changes per list

| List | Before | After |
| --- | --- | --- |
| Home conversations (`CmuxMobileChief/ConversationsHome`) | Leading Read/Unread (gray 0.35); trailing Delete (white in dark), Hide Alerts (indigo) | Trailing Delete (system red), Hide Alerts (`systemIndigo`), Read/Unread (`systemBlue`); context menu unchanged |
| Feed (`CmuxMobileFeed/FeedSwipe`) | Leading Allow / Answer / Read; trailing Deny or Decline or Done, plus Open | Trailing only. Permission: Deny, Allow. Question: Decline, Answer. Others: Done (Undo bar kept), Read/Unread. Open, Copy, Mark read/unread, Done, Mute in the context and `ellipsis` menus. The row pan no longer begins for a rightward drag |
| Files and links (`CmuxMobileArtifacts/ArtifactsBrowser`) | Trailing Copy path (`.gray`) | Trailing Copy path (`systemGray`) |
| Checkpoints (`CmuxMobileAgentChat/ParityViews`) | Trailing Restore (`.orange`) | Trailing Restore (`systemOrange`) |
| Settings lists | No swipe actions | Unchanged |

## How it was verified

`verify/build.sh` on one headless iPhone 17 Pro simulator, `cmux-mobile-sw-ios26` (iOS 26.5), with
`CMUX_MOBILE_MOCK_AUTH=1`. Simulator.app was never opened. Drags were real HID touches sent with `axe`
(`verify/navigation.md`, `verify/swipe-rec.sh`). The simulator was deleted afterwards. The iOS 27
pass was lost when the Mac ran out of processes, and the coordinator then scoped the work to one
simulator. This is mock-mode UI only. It was not checked against a live cmux-next Mac build.
Evidence (git-ignored) is in `verify/evidence/2026-10-13/swipes/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Home Delete in dark mode, before | White capsule, white icon | `before-home-trailing-dark.png` |
| Home swipe left, dark and light | Delete (system red), Hide Alerts (indigo), Unread (blue) | `home-left.png` |
| Home swipe right on a row | Drawer opens and tracks the finger. No action reveal | `home-right-sheet.png` |
| Feed swipe left: question, finished, permission, dark and light | Decline and Answer; Done and Read; Deny and Allow | `feed-dark.png`, `feed-light.png`, `tabs-right.png` |
| Feed swipe right on a row | Drawer opens cleanly. The row does not move | `feed-right-sheet.png` |
| Files and artifacts swipe left, dark and light | Copy path (system gray) | `files.png` |
| Checkpoints swipe left, dark and light | Restore (system orange) | `cp.png` |
| Settings swipe right | Drawer opens cleanly | `settings-right-sheet.png` |

During the first pass the Feed Decline icon (`xmark.bubble`) drew nothing, so it was changed to
`xmark` (`tabs-right.png`).
