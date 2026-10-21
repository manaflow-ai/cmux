# Agent chat, diff, artifacts and Feed: round 4 review

This is a fresh designer review, done on 2026-10-14, of `origin/feat-cnx-ios` at `f054dfb94196`.
That commit was merged into `feat-cnx-ios-design-chat`. I did not change app code. The
`round4/` captures were treated as claims. Every result below comes from my own captures
in `round4-review/`.

**Verdict: NOT signed off.** The round 3 blocker (N1, the viewed state) now passes, and so
do the image viewer, the double slash fix, the AX5 turn card names and the artifact tiles.
Two items still fail:

- **Top-bar buttons.** The real touch area of the glass top-bar buttons is 36 pt high,
  while the drawn circle is 44 pt. A tap on the visible edge does nothing.
- **Diff header folder.** In the file header, the folder of `ConnectionSettings.swift` is
  squeezed to a 4 pt sliver. It draws a cut glyph in front of the name.

Everything else is polish.

## Setup

- `git merge origin/feat-cnx-ios` and `xcodegen`. The `CmuxMobileLinkFFI.xcframework` is identical to
  the one in `worktrees/feat-cnx-ios`.
- Debug and Production simulator builds used
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `-jobs 4`,
  `-derivedDataPath /tmp/cmux-mobile-chat-review4-dd`, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`. Both
  succeeded.
- One headless iPhone 17 Pro (iOS 27.0, 402 x 874 pt) named `cmux-mobile-chat-review4`, deleted at
  the end. Input came from `axe` HID. Frames are AX frames in pt from `axe describe-ui`;
  the dumps are in `round4-review/ax/`. I did not pair with a Mac, use the E2E rig or make
  model calls.
- Every Debug capture is **mock (layout only)**: `CMUX_MOBILE_MOCK_AUTH=1`, with
  `-CmuxMobileDemo chat-feed`, `-CmuxMobileDemoHold chat`, `-cmux-mobile-image-zoom-demo` or
  `-cmuxMobile.dev.slowFaceID YES` as named.
- Screenshots are 402 px wide (1 px = 1 pt) unless the name says `crop`.
- Recording: `02-driver-run-fresh-install-dark-mock.mp4` (98 s, 402 px, H.264, 1.9 MB). The
  1-minute load average was 13.6 at the start and 9.3 at the end. One earlier
  screenshot-only driver run started at a load of 113; it was not used for timing.

## Results

| Item | Result | Evidence and measurement |
| --- | --- | --- |
| **N1 Viewed state shared** | **PASS** | The driver marked `LinkDialer.swift` viewed in the diff. Changes then showed `1 of 3 viewed` (`02` video, at about 75 s). After a relaunch, the turn card row read `Viewed, LinkDialer.swift…` (AX). From the turn card, I opened `ConnectionSettings.swift` and marked it viewed (`04`). `Review` then showed `2 of 3 viewed` (`06`). I marked `TransportKind` in Changes, and the turn card showed all three with green checks (`07`). The title menu's `Agent edits` showed `3 of 4 viewed` (`10`). I marked `transport-report.html` there (`4 of 4`), and the earlier turn's card row became `Viewed, transport-report.html` (AX). "A later edit starts unviewed" cannot be produced in mock. It is covered by `DiffViewedStoreTests.aLaterEditOfTheSameFileStartsUnviewed` (not run here) |
| **N2 Image viewer** | **PASS** | It opens with ✕ and Share. The AX tree now has `Close` (20,66 36x36), `Share` (349,66 28x36) and `Image, connection-settings.png` (`11`, `ax/11-…`). With `-cmux-mobile-image-zoom-demo` the image frame went from 402x268 to **1005x670 (2.5x)** (`13`). A left swipe panned the image to **x −293** (`14`). A swipe down while zoomed was ignored, so the viewer stayed open (`14`, AX). A swipe down at fit size dismissed it. Real double-tap and pinch remain untested (simulator HID limits) |
| **N3 and F11 44 pt targets, in content** | **PASS** | Composer `Add` 44x44, collapsed composer 258x44, Send 44x44, `Jump to bottom` 44x44, `Copy code` 44x44. Tool rows (`Read`, `Thought`, `Ran`) are 362x44, turn card file rows 362x44, `Show N more lines` 138 to 153x44. Message actions are 44x44 (49x49 at AX5). The diff `Mark as viewed`/`Viewed` and `File actions` are 44x44, and the Changes row toggles 44x44. Feed chips are 44 high (`All` 46, `Needs you, 1` 131, `Finished` 87, `Errors` 70) (`15`). Feed Reply, Open, Copy and Share are 55 to 59x44, `Event actions` 44x44, `Show more` 80x44. Artifact chips are 44 high |
| **N3 Top-bar buttons (iOS system bar)** | **FAIL** | The AX frames are 36 high: chat `More` 48x36, the title pill 189x36, `Diff options` 48x36, Feed `Teams` 36x36 and `Filter` 31x36, Workspaces `Filter` 47x36 and `New Workspace` 47x36, Artifacts `List`/`Grid` and `Done` 36x36. The drawn glass circle is 44 pt (y 62–106). Edge taps on the chat `More` (frame y 66–102): y 84 opened the menu; y 64, y 104 and x 384 did **nothing**; x 337 opened it. The title pill gave the same result: y 64 and y 104 did nothing, y 84 opened it. So the real touch area is 36 pt high, and taps on the visible edge of the circle are lost. For contrast, the image viewer's `Close` (also 36x36 in AX) **did** respond at y 63, y 104 and x 17, and `Share` responded 6 pt outside its frame (`12`). So the system bar can give a 44 pt touch area |
| **N4 Diff header path** | **PASS (double slash gone); new defect N8** | `…sport/LinkDialer.swift` has one slash (`02`). For `ConnectionSettings.swift`, the folder text is laid out at **4 pt** wide (`StaticText 45,130 4x15`), so a cut glyph sits before the name. Yet about 40 pt is free between the name and `+6 −3` (`05` crop). The turn card has the same squeeze, with the folder at 8 pt showing a lone `c` (`ax`, frame 296,670 8x15) |
| **N5 AX5 turn card names** | **PASS (polish)** | At AX5 every name is whole, with its extension (`TransportKind.swift`, `LinkDialer.swift`, `ConnectionSettings.swift`). The folder truncates at the head (`…CmuxMobileTransport/`, `…/CmuxMobileSettings/`) and the counts go on their own line (`21`). Polish: the names scale down to fit, so each name has a different size (`ConnectionSettings.swift` is about 15 pt, `TransportKind.swift` about 22 pt). The secondary folder text is about 2x the size of the primary name. Wrap the name at full size instead of shrinking it, and keep the folder smaller than the name |
| **Artifacts grid** | **PASS (folder by claim)** | The type glyph sits in the footer before the name, not on the thumbnail (`19`). `relay-rtt.csv` shows its first lines (`transport,region,p50_ms…`), and links show `rfc-editor.org` and `wireguard.com` (`20`). HTML, image, code, PDF and video thumbnails render. Chips are 44 high at the same y in list and grid. This session had 12 items and no folder. The claim `round4/04-…` shows a `CmuxMobileKit` folder tile with a plain folder glyph; I did not reproduce it |
| **N6 Scroll-to-top flash** | **Polish FAIL (much improved)** | Recorded at 10 fps (`03`, 54.9–55.7 s): the cut jumps near the top and then animates the last screen. The 70 pt blank gap is gone. In one frame (about 100 ms) the `connection-settings.png` tile is drawn **over** the composer, covering `Reply to Claude` (`03b` crop, middle). It settles in the next frame |
| **N7 Menu casing** | **Polish FAIL** | The page menu reads `Files and artifacts`, `Share transcript`, `Stop agent` (`08`). The title menu reads `Copy session ID`, `Continue in…` (`09`). The workspace-tab menu still uses Title Case: `All Workspaces`, `Stop Agent`, `Close Tab` (`18`) |
| Feed quote bubbles right-aligned | **PASS** | The bubbles span x 68 to 386, with a right tail and a `↩ You` caption. `You replied` is right-aligned at x 322 to 385 (`15`) |
| Relaunch persistence | **PASS** | Feed question: I picked `Release candidate` and got `2 of 3`. After a relaunch it still showed `2 of 3` (`16` → `17`). Diff viewed marks survived the relaunch (N1). Note: in mock, a question that was answered fully comes back unanswered after a relaunch without `-CmuxMobileDemo`, because mock re-seeds the Feed. `FeedArchive` is used only in live mode. This is expected for mock and was not judged |
| Face ID waiting state | **PASS (AX5 polish)** | With `-cmuxMobile.dev.slowFaceID YES` at AX5, the primary button shows a spinner and `Waiting f…`. `Always allow car…` is disabled, while `Deny` and `Reply instead` stay enabled (`22`). Polish: at AX5 the label truncates to `Waiting f…`; let it wrap |
| Production ignores mock and demo args | **PASS** | `dev.cmux.mobile.prod` was launched with `CMUX_MOBILE_MOCK_AUTH=1 -CmuxMobileDemo chat-feed -cmuxMobile.dev.mockData YES -cmuxMobile.dev.slowFaceID YES -cmux-mobile-image-zoom-demo`. It shows the normal sign-in (`01`). The Production bundle has no `CmuxMobileDemo`, `CmuxMobileDemoHold`, `MockAgentSession`, `cmux-mobile-row-heights`, `RowHeightProbe` or `cmux-mobile-image-zoom-demo` strings. Only the `cmuxMobile.dev.slowFaceID` and `mockData` key strings remain, as in round 3 |
| F10 Off-screen close | **Polish FAIL (carried over)** | `Close Fix pricing page layout` (30x30 at x 372, y 0) and `Close Refactor transport layer` are still in the AX tree of the workspace chat tabs (`ax/19-…`) |
| F1 Chip badge gap | **PASS** | `Needs you` text ends at x 162, and the badge starts at about 170 (`15`). At rest no badge sits under the fade |

## New findings

- **N8 (should fix): The diff header folder collapses to a glyph fragment.**
  - In the file screen header, `ConnectionSettings.swift` gets a 4 pt folder label, which
    draws a cut character. The turn card row gets 8 pt with a lone `c`.
  - Should be: when the folder cannot fit at least `…/`, drop it (layout priority 0 with
    a minimum of the ellipsis width), or show `…/CmuxMobileSettings/` in the free space before the
    counts.
- **N9: The diff file screen copy.** After marking a file viewed, the body says `Viewed. Tap
  Unmark to show the diff again.`, but the button's label is `Viewed` (a check). Use
  `Tap the check to show the diff again.`, or label the control `Unmark`.

## Fix list for round 5

**Must fix (blocks sign-off):**

1. **Top-bar touch areas.** Give the glass top-bar buttons a 44 pt touch area that matches
   the drawn circle. The touch area must cover the drawn circle, for these buttons: chat
   `More`, `Diff options`, the title pill (44 high), Feed `Teams` and `Filter`, Workspaces
   `Filter` and `New Workspace`, and Artifacts `List`/`Grid` and `Done`. The image viewer's
   `Close` already does this; reuse its approach. Verify with edge taps at y 63 and y 104.
2. **N8.** Remove the folder-label sliver in the diff header and the turn card.

**Polish:**

3. **N6.** Keep image tiles below the composer during the scroll-to-top cut (one frame).
4. **N7.** Use sentence case in the workspace-tab menu: `All workspaces`, `Stop agent`,
   `Close tab`.
5. **N5.** At AX sizes, wrap turn card names at full size instead of scaling them down.
   Keep the folder smaller than the name.
6. **F10.** Hide the off-screen `Close <title>` buttons from the AX tree.
7. At AX5, let `Waiting for Face ID…` wrap.
8. **N9.** Fix the copy on the viewed diff file screen.

## Not verified here

- Real double-tap and pinch zoom (simulator HID). The zoom path was checked with the DEBUG
  switch.
- VoiceOver modality of the image viewer: `describe-ui` still lists the transcript behind
  it, and that output cannot show whether VoiceOver treats the viewer as modal.
- The artifact folder tile (none in my session; see the claim `round4/04`).
- "A later edit starts unviewed" at runtime (mock has no second edit of the same file; the
  unit test covers it).
