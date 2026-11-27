# Agent chat, diff, artifacts and Feed: round 3 review

Fresh designer review, 2026-10-14, of `origin/feat-cnx-ios` at `6187529ccb1e`, merged
(fast-forward) into `feat-cnx-ios-design-chat`. I did not change app code. The `round2/` and
`round3/` captures were treated as claims. Every result below comes from my own captures in
`round3-review/`.

**Verdict: NOT signed off.** Every round 1 must-fix (F1 to F4) now passes, and so do the
brand mark, the Mode order, the placeholder, the thumbnails and the relaunch checks. One
functional defect blocks sign-off: the diff's **viewed state is lost** whenever the Changes
list or a diff is opened again (N1). Image viewer double-tap zoom could not be driven from
the simulator. Its code also has no pan when zoomed (N2).

## Setup

- `xcodegen`, then Debug and Production simulator builds with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `-jobs 4` and
  `-derivedDataPath /tmp/cmux-mobile-chat-review3-dd`. Both built. The xcframework is identical to the
  one in `worktrees/feat-cnx-ios`.
- One headless iPhone 17 Pro (iOS 27.0, 402 x 874 pt) named `cmux-mobile-chat-review3`, deleted at
  the end. Simulator.app was never opened. Input came from `axe` HID, and frames are AX frames
  in pt from `axe describe-ui` (raw dumps are in `round3-review/ax/`). I did not pair with a
  Mac, use the E2E rig or make model calls.
- Every Debug capture is **mock (layout only)**: `CMUX_MOBILE_MOCK_AUTH=1`, sometimes with
  `-CmuxMobileDemo chat-feed`, `-CmuxMobileDemoHold chat`, `-cmux-mobile-row-heights` or
  `-cmuxMobile.dev.slowFaceID YES`.
- Screenshots are 402 pt wide (1 px = 1 pt) unless the name says `crop` or
  `contact-sheet`.
- Recording: `02-driver-run-dark-mock.mp4` (77 s, 402 px, H.264). The 1-minute load was 8.6
  at the start and 8.9 at the end.

## Round 1 failures and the named items

| Item | Result | Evidence and measurement |
| --- | --- | --- |
| F1 Feed chips at AX5 | **PASS** (polish note) | At AX5 the chips are 71 pt high and grow with the text (`All` w83 h71, `Needs you, 2` w301 h71, `Finished` w210 h71, `Errors` w155 h71). The glyphs sit inside the capsule, and the chip row scrolls to `Finished` and `Errors` (`16-…`, `18-…`). Polish: at rest the `2` badge of the last visible chip touches the `u` and its right half is under the trailing fade (`17-…`). Add 4 pt before the badge, and end the fade before a badge |
| F2 Context meter reads as a meter, with details | **PASS** | A filled pie wedge in a ring, followed by `24%` (`03-…`). It no longer looks like a spinner. AX: `Context used`, value `24 percent, 48K of 200K tokens`, 59 x 44. A tap opens a popover: `Context window / 24% used`, a bar, and `48K of 200K tokens` (`04-…`). A new chat shows `0%` |
| F3 Chat at AX5 rests on the composer | **PASS (measured)** | At AX5 after the turn, the action row (Copy, Share, Retry, More, 49 x 49 each) ends at y 730. The composer capsule starts at y ≈ 757, a 27 pt gap. At the default size the gap is 26 pt (action row bottom 758, capsule ≈ 784; `07-…`, `19-…`). `-cmux-mobile-row-heights`: for all 30 rows the placed height equals the measured `sizeThatFits(width, nil)` height (`20-…txt`, 0 of 30 differ, including the 11 328 pt final turn) |
| F4 Diff file header at AX5 | **PASS** (bug noted) | The `M` badge grows with its glyph. The name wraps to two readable lines (`LinkDi-` / `aler.swift`), with the folder collapsed to `…/`. `+15 −6` is on its own line. Mark as viewed and File actions are 44 x 44 (`21-…`, `22-…`). Bug: the visible path is `…port//LinkDialer.swift`, and the AX label is `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport//, LinkDialer.swift`. The folder carries a trailing `/` and another one is added (N4) |
| F5 44 pt targets | **PASS for the listed set; FAIL for the rest** | 44 or more: message actions (Copy, Share, Retry, More 44 x 44; 49 x 49 at AX5), Feed Reply, Open, Copy and Share (56 to 59 x 44), Feed `Event actions` 44 x 44, Feed `Show more` 80 x 44, Feed question `Next` 77 x 44 and `Back` 44 x 44, Changes and diff `Mark as viewed` 44 x 44, File actions 44 x 44, Send and Stop 44 x 44, context meter 59 x 44, permission buttons 354 x 48 to 54, `Reply instead` 120 x 44, Back nav 44 x 44. **Still under 44:** see N3 |
| F6 New chat brand mark | **PASS** | An empty Claude chat shows the orange Claude asterisk in a 48 pt disc, `What should Claude do?` and `cmux on Aziz's Mac Studio` (`23-…`) |
| F7 Demo driver | **PASS** | On a fresh install the driver skipped `Choose a space` and ran the whole script: Feed, question, reply, chat turn, permission, question, scroll, diff, Changes (`01-…`, sampled every 7 s). It types without raising the keyboard, and no swipe-typing tip appeared during the run. The tip appears only after a manual tap in the composer, which is expected system behaviour |
| F8 Mode order | **PASS** | Composer menu: Model, then Mode `Manual, Accept edits, Plan, Auto`, then Effort (`05-…`). Title menu Mode: `Manual, Accept edits, Plan, Auto` (`06-…`). The same order is used in both places |
| F9 Composer placeholder | **PASS** | The collapsed composer, its AX label and the expanded field all say `Reply to Claude`. An empty chat says `Ask Claude`. At AX5 it truncates to `Reply to…`, which is acceptable |
| F10 Off-screen close button | **FAIL** (polish, carried over) | `Close Refactor transport layer`, 30 x 30 at x 372, y 0, is still in the AX tree of the workspace chat tab with the Files sheet open (`ax/`) |
| F11 Scroll-to-bottom arrow | **PASS for look, FAIL on size** | `Jump to bottom` has a dark disc background and sits 12 pt above the composer (bottom y 724, composer ≈ 736; `08-…`). Tapping it returned to the last row. It is 36 x 36 and partly covers the table row behind it (`~350 ms`). Make the hit area 44 |
| SPEC 19 Artifacts grid thumbnails per type | **PASS** (note) | HTML renders a page snapshot, the PNG shows the image, `.rs` shows a code excerpt, the PDF shows its first page, and `demo.mp4` shows a frame (`24-…`, `25-…`). Chips sit at y 138 in both list and grid (`26-…`), with a trailing fade. Notes: `relay-rtt.csv` falls back to a generic document icon, although it is text and should show its first lines. The two links show only a link glyph. The type badge sits on the thumbnail content (the globe covers `LinkDialerTests`), and the PDF badge is clipped at the tile's bottom edge. I saw no folder tile in this session, so the round 3 folder claim is unverified |
| Image viewer double-tap zoom | **Could not verify; code defect** | The transcript image opens a full-screen viewer with ✕, the title and Share (`09-…`), and a swipe down dismisses it. Double-tap did not zoom with two methods: (1) `axe batch` with two physical `touch --down --up` pairs 80 ms apart, and (2) `axe batch --tap-style simulator` with two taps 50 ms apart (`10-…`, unchanged). axe has no pinch. The viewer is also **absent from the AX tree**: `describe-ui` still lists the transcript behind it, so VoiceOver reachability of ✕ and Share is unconfirmed. In code (`ZoomableImage`), zoom is `scaleEffect` only, with no offset, so a zoomed image cannot be panned. The dismiss `DragGesture` is also attached to the same view (N2) |
| Feed quote bubbles right-aligned | **PASS** | The bubbles sit at x 68 to 386 with a right tail and a `↩ You` caption (`12-…`). At AX5 they stay right-aligned, and the text wraps inside (`16-…`) |
| Relaunch persistence | **PASS** | Feed question: I picked `Release candidate` (auto-advanced to `2 of 3`), then selected `Feed inline answers`. After a relaunch it showed `2 of 3` with that box `Selected` and the others `Square` (`13-…` → `14-…`). Read flag: I opened the `ship it to staging` event (it had `Unread`), then relaunched; it had no `Unread` dot, and the next event kept its dot (`15-…`) |
| Face ID waiting state | **PASS** | With `-cmuxMobile.dev.slowFaceID YES`, the primary button became a spinner and `Waiting for Face ID…` (354 x 48). `Always allow cargo test in this workspace` was DISABLED, while `Deny` and `Reply instead` stayed enabled (`11-…`) |
| Production | **PASS** | `dev.cmux.mobile.prod`, launched with `CMUX_MOBILE_MOCK_AUTH=1 -CmuxMobileDemo chat-feed -cmuxMobile.dev.mockData YES -cmuxMobile.dev.slowFaceID YES`, shows the normal sign-in (`27-…`). The binary and frameworks contain no `CmuxMobileDemo`, `MockAgentSession`, `cmux-mobile-row-heights` or `RowHeightProbe` strings. Only the `cmuxMobile.dev.slowFaceID` key string remains, and its delay is compiled out |

## New findings

- **N1 (blocker): Diff viewed state is lost on every new entry point.**
  - The driver marked `LinkDialer.swift` viewed in the diff (the green check), went back and
    opened Changes. Changes showed `0 of 3 viewed` (`28-…`).
  - I reproduced it by hand. In Changes I marked two files viewed (`2 of 3 viewed`). I went
    back to the chat, opened `ConnectionSettings.swift` from the turn card and marked it
    viewed, then opened `Review`. Changes showed `0 of 3 viewed`, with all three `Mark as
    viewed` (`29-…`).
  - Viewed state appears only within one Changes stack. Keep it per turn (or per file hash)
    in the session store, so the transcript diff, Changes and a relaunch all share it.
- **N2: Image viewer zoom.**
  - Add pan while zoomed: a drag offset clamped to the image bounds, or a `UIScrollView`
    zoom host.
  - Run the dismiss drag only at scale 1.
  - Make the viewer's ✕, Share and image reachable in the accessibility tree.
- **N3: Hit targets still under 44 pt (AX frames):**
  - Composer `Add` 36 x 36 and `Model` 148 x 34.
  - Code-block `Copy code` 32 x 32.
  - `Jump to bottom` 36 x 36.
  - Collapsed tool rows (`Read`, `Thought`, `Ran`): full width but 32 high.
  - Chat nav `More` and `Diff options`: 48 x 36 (the glyph image is 44 x 44, but the button
    frame is 36 high).
  - Feed and Workspaces nav `Teams` 36 x 36, `Filter` 31 to 41 x 36, `New Workspace` 41 x 36.
  - Feed filter chips: 36 high at the default size.
  - Artifacts `Grid`/`List` and `Done` 36 x 36, artifact chips 34 high.
- **N4: Double slash in the diff header path.** `…port//LinkDialer.swift` (visible) and
  `CmuxMobileTransport//` (AX label). Join the folder and name without a duplicate separator.
- **N5: Turn diff card at AX5.** File names hyphenate and are middle-truncated into unreadable
  fragments (`Trans-` / `port…wift`, `Connec-` / `tion…wift`; `19-…`). Apply the diff header
  rule: wrap the full name and keep the extension, with the counts on the next line.
- **N6: Programmatic scroll to top shows fragments.** For about 300 ms during the driver's
  jump over a 27-page transcript, a 70 pt blank appears between the table and `To try it
  from the simulator`, and image tiles are drawn over text and the composer (`30-…`, 10 fps).
  It settles correctly. Polish: animate to an estimated offset, then snap, or jump without
  animation.
- **N7: Menu casing differs.** The page menu says `Files and Artifacts` and `Copy Session ID`;
  the title menu says `Files and artifacts` and `Copy session ID` (`31-…`). Use sentence case
  in both.
- Display math wider than the Feed column is cut at the right edge with no scroll affordance:
  `𝒰(−0.` (`12-…`). This is minor; scroll it as code blocks do.

## Fix list for round 4

**Must fix (blocks sign-off):**

1. **N1.** Persist the diff viewed state per turn and file in the session or store. It must
   be the same in the transcript diff, the Changes list and after relaunch. Add a test:
   mark viewed from the transcript diff, then open Review and expect `1 of 3 viewed`.

**Should fix:**

2. **N2.** Image viewer:
   - Pan while zoomed.
   - Dismiss drag only at scale 1.
   - Make the viewer's ✕, Share and image reachable in the AX tree.
   - Add a DEBUG hook or a unit test that proves double-tap toggles the zoom to 2.5, since
     simulator HID double-taps do not reach it.
3. **N3.** Bring the listed controls to 44 x 44 hit areas (`contentShape` or `frame(minWidth:
   44, minHeight: 44)`). Keep the glyph sizes.
4. **N4.** Remove the double slash from the diff header path.
5. **N5.** Turn card file names at AX sizes: wrap the whole name and keep the extension.
6. **F11 size.** Make the jump-to-bottom button 44 pt.

**Polish:**

7. **F10.** Hide the off-screen `Close <title>` button from the AX tree.
8. **F1 note.** Add 4 pt before the chip badge, and keep the fade off the last visible badge.
9. **Artifacts:**
   - Text and CSV files show their first lines.
   - Links show a favicon or a page title.
   - Move the type badge into a corner with a scrim, so it does not cover content; the PDF
     badge must not be clipped.
10. **N6.** Fix the scroll-to-top fragments. **N7.** Use one menu casing. Scroll display math
    in the Feed.

## Not verified here

- Double-tap and pinch zoom (simulator HID limits, see above).
- An artifact folder tile (none in this mock session).
- Item 6 (hidden unmatched markdown markers mid-stream) and the ACP title from
  `session_info_update`.
- Persistence of a chat tab created on the phone (in mock, tabs live in memory; it needs a
  paired Mac in E2E).
