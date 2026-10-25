# Chief and the iMessage team's conversation GUI

Branch `feat-cnx-ios-imsg`, 2026-10-13. The user asked whether Chief really uses the iMessage
team's GUI, because of these defects: transcript rows unblurred behind the header and status
bar, a tapback heart over the header, and a reply thread that looked different. This page
covers what was different, why, and the side-by-side proof against the team's own host.

## Source of truth

- The package is `Packages/iOS/CmuxConversation`, identical to `origin/feat-imsg-parity-gui`
  at c4741ca97f05. That commit is also `origin/feat-imsg-integration`.
  `git diff origin/feat-imsg-parity-gui -- Packages/iOS/CmuxConversation` is empty.
- The reference host is the team's DEBUG lab, `ConversationLabView`
  (`Packages/iOS/CmuxMobileShellUI`). It is the only `ConversationViewController(` call
  outside the package. The cmux iOS app shows it full screen when
  `CMUX_UITEST_CONVERSATION_LAB=ws://…/ws?conversation=direct` is set. It puts the controller
  in a `UINavigationController` with the bar hidden, and the package draws the header,
  backdrop and composer and owns the safe areas and the keyboard.

## What was different, and why

Before this branch our copy of the package was behind the team's branch, and an earlier agent
of ours had edited 14 files in it:

| Local edit | Effect | Now |
| --- | --- | --- |
| Deleted `ConversationHeaderGeometry` group-cluster slots and `ConversationTranscriptMetrics` sender-name, avatar and caption-spacing functions, with their tests | Group header cluster, details-page cluster, sender-name line, avatar position and transcript spacing used older hand-tuned numbers instead of the team's real-device measurements | Team's code |
| `ConversationTheme.captionLineSpacing` removed | Spacing grew with tall-script languages (the team fixed this) | Team's code |
| `incomingRowsFollowTimestampDrawer` option (cells, view controller) | Incoming bubbles slid with the send-time drawer in 1:1 | Removed. Proposed upstream ([imsg-upstream-requests.md](imsg-upstream-requests.md) #1) |
| `configureHeaderIfNeeded` in `viewIsAppearing` | Worked around an empty header when the store was already connected | Removed. The host calls the public `setBackUnreadCount(_:)`, as the lab's unread badge does, once the screen is in a window |
| Unread pill hidden by default | Covered the same empty-header case | Removed (same fix) |
| `ConversationComposeViewController.serviceLine` | Replaced "iMessage" in New Message | Removed. Proposed upstream (#2) |
| Lab verbs `timestamps`, `react` | Drove demos without touches | Removed. The demo driver reacts through `ConversationStore.react`; the drawer is driven with real touches |

The three defects in the user's screenshot are **the package's own rendering**. They reproduce
pixel for pixel in the team's lab host on the same data:

- **Rows behind the header.** On iOS 26 the header backdrop is the team's measured color wash
  (peak 0.60 opacity in dark mode), so rows stay readable behind it. On iOS 27 rows are blurred.
  Both hosts match (`01-open`, `02-under-header` on every run).
- **Tapback near the header.** The badge passes under the header the same way in both hosts
  (`10-heart-under-header`).
- **Reply thread.** The outlined quote with its connector line matches in both hosts
  (`14-reply-in-transcript`).

These are listed for the team in [imsg-upstream-requests.md](imsg-upstream-requests.md) #3
(not patched here).

## Host changes (`CmuxMobileKit/Sources/CmuxMobileChief`, public API only)

- `ChiefConversationScreen` passes `ConversationPresentationOptions` for the placeholder
  ("Message Chief"), the start header ("Chief", "Runs your agents on your Macs") and the
  history symbol. It hides the bar and the tab bar, like the lab.
- Header: `setBackUnreadCount(_:)` in `viewIsAppearing`, so the avatar and name are there
  from the first frame. The shared Chief store is usually connected before the screen
  exists, and without this the package would not configure the header until the next store
  change.
- **Back swipe (fixed, was dead).** SwiftUI turns the pop recognizers off while the bar is
  hidden. On iOS 26 and 27 the edge swipe is driven by `interactiveContentPopGestureRecognizer`,
  not the edge recognizer. In the logs, only the content pop was asked to begin, once the
  finger was 30 pt in. The transcript's scroll pan also tracks sideways drags (the send-time
  drawer) and took the drag first. The container now does three things:
  - It re-enables both pops on every layout.
  - It limits the content pop to drags that start in a 16 pt edge strip. A rightward drag on
    a bubble still replies, and a leftward drag still opens send times.
  - It makes every transcript pan wait for the pops to fail. They fail as soon as a drag
    starts outside the strip.

  This is what Messages does: edge swipe back, and a left swipe in the content for times.
- DEBUG: `CMUX_MOBILE_CHIEF_SIM=<ws url>` points Chief at `services/conversation-sim` through the
  package's `ConversationSimBackend`. `-cmux-mobile-demo chief-open` opens Chief.

## How it was verified

- **Reference build.** A detached checkout of `origin/feat-imsg-parity-gui` at
  `/tmp/imsg-ref`, built for the simulator with Xcode 27.0 (arm64). Two local workarounds
  were needed, and neither touches the package:
  - One line of their app shell was removed: `.toolbarMinimizeBehavior` does not exist in
    this SDK.
  - The full app crashes at launch on iOS 26.5 (`Symbol not found: _swift_initBorrow`, from
    swift-collections' `InternalCollectionsUtilities` built by Xcode 27). Upstream request
    #4. On iOS 26 the reference is therefore their `ConversationLabView.swift`, copied
    unchanged into a scratch app (`/tmp/imsg-ref-host`) and shown the way their root view
    shows it.
- **Simulators.** Headless `cmux-mobile-imsg-ref-ios26` and `cmux-mobile-imsg-ours-ios26` (iOS 26.5), and
  `cmux-mobile-imsg-ref-ios27` and `cmux-mobile-imsg-ours-ios27` (iOS 27.0), all iPhone 17 Pro Max.
  Simulator.app was never opened.
- **Data.** `verify/imsg-sims.sh` starts two conversation-sim servers from their checkout:
  same seed, same instant, bots quiet, no injected failures. One feeds each host, so a send on
  one side never appears on the other. John's last three messages are fixed.
- **Driving.** `verify/imsg-parity.sh` sends the same real HID touches to both simulators at
  once with `axe`. It takes screenshots per state and records video for motion, using
  `imsg-peak.py` to pick the deepest frame of a drag. `imsg-sbs.py` builds ref | ours | pixel
  diff sheets.
- **Evidence** (git-ignored): `verify/evidence/2026-10-13/imsg/<ios26|ios27>-<dark|light>/`
  (`NN-state-{ref,ours,sbs}.png`, `*.mp4`, `*-frames/`), plus `ios27-dark-ax/` for Dynamic Type
  AX-XL.

## Pixel diffs

"Changed" is the share of pixels that differ by more than 24 of 255 between the two hosts on the
same state.

| State | 26 dark | 26 light | 27 dark | 27 light | 27 dark, AX-XL |
| --- | --- | --- | --- | --- | --- |
| Open (bottom, rows under header) | 0.42% | 0.34% | 0.99% | 0.70% | 1.06% |
| Rows under the header after a slow drag | 49% ¹ | 0.30% | 1.67% | 1.15% | 1.12% |
| Send-time drawer held | 1.58% | 0.34% | 2.44% | 2.13% | 1.46% |
| Long-press menu and tapbacks | 0.26% | 1.26% | 0.35% | 0.35% | 0.36% |
| Heart tapback | 0.39% | 0.33% | 1.71% | 1.43% | 1.06% |
| Reply thread in transcript | 0.48% | 1.37% | ² | ² | ² |
| Details page | 0.00% | 0.00% | 0.50% | 0.25% | ² |

- Every sub-3% diff sits in the intentional differences: the back button's unread count (the
  lab counts its second conversation; Chief has none), the trailing symbol (video in the lab,
  history in Chief), the placeholder ("iMessage" or "Message Chief"), and the start header's
  service line.
- ¹ Touch-driven scrolls land a few points apart, because the two `axe` processes do not
  deliver at the same instant. Flicks (`03`/`04`) differ the same way. Content and rendering
  match; the sheets show the same rows.
- ² From the reply step on, those runs diverged because of the harness, not the GUI. In the lab
  the reply swipe or the composer missed the synthesized input. The following tap on the
  trailing button then started a voice recording (iOS 27) or raised the microphone prompt
  (AX-XL), while Chief continued. Steps before the divergence match.

## Behavior matrix

"Same" means the lab host and Chief behave identically on every run listed.

| Behavior | iOS 26 | iOS 27 | Result |
| --- | --- | --- | --- |
| Header avatar and name from the first frame | Same | Same | Pass (needs the host fix above) |
| Rows under header: iOS 26 wash, iOS 27 blur; status bar legible | Same | Same | Pass, package behavior |
| Fast flick, rest, back to bottom | Same content | Same content | Pass |
| Swipe-left send times (held, released) | Same | Same | Pass. Incoming stay still, as in Messages. "All bubbles slide" needs upstream #1 |
| Long-press menu and classic tapbacks, heart applied | Same | Same | Pass |
| Tapback badge under header | Same | Same | Pass, package behavior |
| Reply from the menu (thread view, send, quote in transcript) | Same | Same | Pass (`t27c` run and the 26 runs) |
| Reply by right swipe with synthesized touches | Same (both) | Missed in the lab on one run | Inconclusive: `axe` drags start the reply swipe unreliably in both hosts |
| Composer focus, typing, send, delivery "Read" | Same | Same | Pass. The lab missed typed input twice; Chief never did |
| Keyboard interactive dismiss | Same (offsets differ) | Same | Pass |
| Incoming message while scrolled up | Same | Same | Pass |
| Typing indicator | Same | Same | Pass |
| Not Delivered (send fails) | Chief "Not Delivered"; the lab's send landed after the failure window closed | Same | Pass (timing flake in the lab on 26) |
| Header tap → details page, back | Same | Same | Pass |
| Left-edge swipe back to Home | Chief pops interactively (the lab is a root and has nothing to pop) | Same | **Fixed** in this branch. Before: dead on both OS versions |
| Edge swipe and send-time drawer do not fight | Drawer still opens, edge pops | Same | Pass |
| Dynamic Type AX-XL | not run | Same through the reply step | Pass up to the harness divergence |
| VoiceOver labels in the header and composer | — | Back, Contact photo, John Appleseed, Add, Message, Record Audio: same | Partial. The history button reads "Call" (upstream #5). The closed team drawer's "Add team" control is still in the accessibility tree under Chief (shell issue, not Chief's) |
| Reduce Motion, images from Photos, link previews, New Message sheet | — | — | Not covered in this pass |

## Follow-ups

- Upstream #1 (incoming rows follow the drawer) and #2 (New Message service line) must land
  before Chief can meet "all bubbles slide" and show no "iMessage" text in New Message
  without patching the package.
- Shell: hide the closed team drawer from accessibility.
