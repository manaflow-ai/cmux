# Agent chat, diff viewer, artifacts and Feed: design spec

Designer pass, 2026-10-14, on `origin/feat-cnx-ios` `1311e6d57acc`. Scope: agent chat
(`CmuxMobileAgentChat`), diff viewer (`CmuxMobileDiff`), artifacts browser (`CmuxMobileArtifacts`) and Feed
(`CmuxMobileFeed`). I did not change any app code.

## Setup and limits

- Debug simulator build (`-jobs 4`, derived data `/tmp/cmux-mobile-chat-design-dd`). One headless
  iPhone 17 Pro, iOS 27.0, 402 x 874 pt, named `cmux-mobile-design-chat` (deleted afterwards).
  Simulator.app was never opened. Input came from `axe` HID. I never paired with a Mac and
  did not use the E2E rig.
- Every capture is **mock (layout only)**: `CMUX_MOBILE_MOCK_AUTH=1`, `MockAgentSession`, and
  `FeedStore` mock items. Text, counts and timings are sample data. Layout, motion and
  state handling are real.
- Screenshots are in `screens/` at 402 x 874, so 1 px = 1 pt. AX frames (pt) come from
  `axe describe-ui`.
- Load: the 1-minute load average was 85 to 136 for the `-CmuxMobileDemo chat-feed` burst
  (screenshots only, never used for timing). It was 8 to 24 during both recordings.
- Videos in `video/` are 402 px wide H.264:
  - `new-chat-keyboard-stream-permission-question-dark-mock.mp4` (81 s): new Claude chat,
    send, stream, permission, Allow, two-step question, final answer.
  - `stream-permission-dark-mock.mp4` (11 s): start of the stream up to the permission
    sheet.

## Blockers

1. **The diff viewer clips long lines and the gutter scrolls away.**
   - In unified view, any line wider than the viewport is cut at about 300 pt:
     `let transport: @Sendable () -> Trar`, and line 14 ends at `try await icePro`. A
     fragment from another scroll offset is drawn into some lines (`Mac ovezort`,
     `SignalingCl:EProvider`, `WebRTCbrs`). Screenshot: `diff-unified-clipped-lines.png`.
   - After a horizontal pan, the clipped lines are empty. The line-number gutter and the
     +/- column scroll off with the code, so you can no longer tell which line you are on.
     Screenshot: `diff-hscroll-gutter-scrolls-away.png`.
   - Should be: each line renders its full width inside one horizontal scroll view shared
     by the code column. The 2 x 28 pt number gutter and the 14 pt +/- column stay pinned
     on the left, as in GitHub mobile. Show a horizontal scroll indicator while panning.
     The longest line sets the content width.
2. **Wrap mode overlaps rows.**
   - At the bottom of `diff-wrap-overlap.png`, the wrapped `return MacLink(stream: channel)`
     (old 18) is drawn under `switch transport() {` (new 17). The row height is measured
     before wrapping finishes.
   - Wrapped continuations start at code column 0, so indentation is lost.
   - Should be: the row height comes from the laid-out text. Continuations use a hanging
     indent equal to the line's leading whitespace, so they align with its first character.
3. **Feed at AX5 overlaps text.** Screenshot: `feed-ax5-overlap.png`.
   - The markdown web view clamps to its Large height, so `green: 412` is drawn under
     `Show more`.
   - The source line reads `Claude · ( 1m`: `cmux` is clipped to one glyph.
   - The filter chips run off screen (`Finished` and `Errors` are missing) with no scroll
     affordance.
   - Should be: the body's measured height is recomputed when Dynamic Type changes, and the
     Show more cap is 8 lines at the current size. At AX sizes the source line wraps under
     the name instead of truncating, and the chips scroll horizontally with a trailing fade.

## Majors

4. **The status bar collides with the chat.**
   - Chat opened as a workspace tab (browser-style bottom toolbar) has no top bar.
     Transcript text scrolls under the clock and battery with no scrim (`demo.mp4. Relay
     timings…` behind 9:41). Screenshot: `chat-permission-codex-statusbar-overlap.png`.
   - Chat pushed from the Feed has the bar, but rows are cut hard at y = 115 under it
     (`chat-demo-queued-stall.png`).
   - Should be: the iOS 26 soft scroll-edge effect (`.scrollEdgeEffectStyle(.soft, for:
     .top)`) on both, as in the ChatGPT and Claude iOS apps, so text fades out under the
     status bar.
5. **Blank gap while streaming.** The answer streams with a gap of about 170 pt between the
   table and `To try it from the simulator:` that closes on the next chunk
   (`chat-stream-gap-run02.png`). The Feed has the same gap of about 130 pt above a question
   card on its first frame (`feed-demo-s002.png`). Should be: no estimated heights in the
   visible region. Hold the last measured height until the new one is known, and never
   insert empty space.
6. **Raw markdown flashes while streaming.**
   - `Short answer to *Make the transport layer switchable between` shows a literal `*`
     until the closing marker arrives (`chat-stream-gap-run03.png`).
   - Should be: hide an unmatched emphasis or code marker at the stream tail, as ChatGPT
     and Claude do, and render it once it closes.
7. **Tables and code cut off without a scroll affordance.**
   - The table header `Survives network chang` is cut at the right edge.
   - Bash `nx-remote -- swift test --package-path cmux-mobile-` is cut.
   - The inline diff in the transcript is cut (`chat-permission-sheet-dark.png`).
   - The Feed wraps code mid-identifier (`cachedHei/ght`, `feed-demo-s005.png`).
   - Should be: code and tables scroll horizontally inside their card, with a 16 pt
     trailing fade while more content is off screen. The Feed must not soft-wrap code;
     use the chat's behavior.
8. **Multi-select questions look single-select.** `Choose any` options use empty circles
   (radio style), in chat and Feed (`chat-question-multiselect-radios.png`,
   `feed-question-2of3.png`). Should be: rounded-square checkboxes (`checkmark.square.fill`
   when on) for any-of questions, and circles only for one-of questions.
9. **The question card mixes auto-advance with a Next button, and the card is a
   navigation target.**
   - On a single-select step, tapping an option advances at once, yet a `Next` button is
     shown on that step (`feed-demo-s002.png` versus the result).
   - In the Feed, my tap meant for `Next` landed on the card after the layout moved and
     opened the chat tab, leaving the Feed mid-answer.
   - Should be: one rule. Either select and advance with no Next on single-select steps,
     or select and require Next. Only the event header and body open the tab; the
     question card's padding and gaps never navigate.
10. **Feed answer progress and read state reset on relaunch.**
    - After step 1 of 3 was answered, a relaunch showed `1 of 3` with nothing selected
      (`feed-question-2of3.png` → `feed-after-relaunch-progress-lost.png`).
    - The unread dot came back on an event I had opened.
    - Events persist; the draft answer and read flags do not.
    - Should be: persist partial question answers (per question id) and read flags in
      `FeedArchive` with the events.
11. **No "Waiting for Face ID…" state.**
    - With mock auth, `Allow once` resolves instantly to `Allowed once …`
      (`chat-after-allow-no-faceid-wait.png`), so the waiting state could not be seen.
    - Should be: when Allow is tapped, the button changes to a spinner with "Waiting for
      Face ID…" (string `FeedStore.waitingForFaceID`). The other options are disabled and
      Deny stays enabled. The button returns to `Allow once` when Face ID is cancelled.
    - Add a DEBUG toggle that delays the mock signature by 2 s so this state can be
      captured.
12. **A new session keeps the title "New session".**
    - After the first prompt and a full turn, the title pill still reads `New session`
      (`chat-turn-r005.png`).
    - ChatGPT and Claude set a title after the first reply.
    - Should be: use the ACP session title when the agent sends one. Otherwise use the
      first prompt, trimmed to 40 characters.
13. **Hit targets under 44 pt** (AX frames in pt):

    | Control | Size (pt) | Required |
    | --- | --- | --- |
    | Remove queued message | 11 x 11 | 44 x 44 |
    | Question `Back` | 35 x 18 | 44 high |
    | `Show more` (Feed) | 80 x 18 | 44 high |
    | `Show N more lines` (chat diff) | 115 x 16 | 44 high |
    | `Reply instead` | 97 x 18 | 44 high |
    | Feed `Event actions` | 32 x 24 | 44 x 44 |
    | Composer Send and Stop | 36 x 36 | Fine visually; extend the hit area to 44 with `contentShape` |

## Polish

14. "Show 1 more lines" should be "Show 1 more line" (`ConnectionSettings.swift` edit,
    chat).
15. The permission card title uses the ✋ emoji as its icon. Use an SF Symbol
    (`hand.raised.fill`) in the warning tint, like the other tool rows.
16. Commands are truncated in the middle, at a token: `Ran git add -A &&…erge --continue`,
    `Allowed once cargo test…--nocapture`. Truncate at the tail, and show the full command
    on tap.
17. Empty new chat:
    - The placeholder is `Reply to Claude`. Use `Ask Claude` when there are no turns.
    - The sparkle glyph is generic. Use the harness glyph (the Feed's Claude asterisk).
    - The empty state jumps 6 pt when the composer grows to 2 lines
      (`chat-empty-keyboard.png` → `chat-empty-typed.png`). Keep it centered in the space
      above the composer.
18. The `Stop Agent` page-menu item is enabled while no turn is running
    (`chat-page-menu.png`). Disable it, or hide it when idle.
19. Artifacts:
    - Every grid tile shows the same `</>` glyph (`artifacts-grid-generic-thumbs.png`).
      Render the first 12 lines of code or text, or an image or PDF thumbnail, as in the
      ChatGPT Library.
    - The chip row sits at y = 187 in list view and y = 155 in grid view; use one y.
    - The chips are cut (`C…`) with no fade.
20. Split diff on a 402 pt phone truncates every line at about 22 characters
    (`diff-split-truncated.png`). Offer Split only when the width is 700 pt or more
    (landscape or iPad), as GitHub mobile does. Keep Unified on phones.
21. The Feed `1 new` pill sits on top of body text (`feed-demo-s005.png`). Give it a glass
    background and place it 8 pt below the filter chips.
22. The demo driver `-CmuxMobileDemo chat-feed` stalls:
    - `t-claude` now opens in its waiting state with a pending question. The driver's send
      is queued, its permission wait times out, and its `answerQuestion(q-transport)` is
      not applied (`chat-demo-queued-stall.png`).
    - The iOS "slide to type" keyboard tip also covers the composer on a fresh simulator.
    - Point the driver at a fresh session, and dismiss the tip in the recording script.

## What works (keep)

- **Feed quote bubbles** are right-aligned with a right tail, have a 12 pt "↩ You" caption
  above, and use 286 pt bubbles in a 318 pt column (`feed-dark.png`, `feed-light.png`).
  This meets the right-aligned requirement and matches the iMessage reply look.
- **Permission sheet:**
  - White primary `Allow once` with a Face ID glyph, `Always allow …` and a red `Deny`.
  - All buttons are full width, 48 to 54 pt high, with 8 pt gaps. `Reply instead` sits
    below.
  - The sheet docks above the composer, and the tool card stays visible above it
    (`chat-permission-sheet-dark.png`).
- Queued follow-up rows, the `Working 32s` status, and collapsed `Ran 2 commands`.
- `You answered` summary pills, right-aligned. The turn diff card (`3 files changed +37 −9 /
  Review`), Copy, Share and Retry, and the turn duration.
- The Changes list:
  - Per-file A and M badges, path tails and +/− counts.
  - The viewed checkmark.
  - A 5-segment ratio bar.
  - `0 of 3 viewed`.
  - Previous and next file, and Mark viewed in the floating bar (`diff-changes-list.png`).
- Word-level highlights render (`, transport: @escaping @Sendable () -> TransportKind`).
- Light mode is correct in the Feed. Chips, bubbles and cards change color with no
  dark-only colors.

## ACP web UI features missing on the phone

- **Context or usage meter.** `usage_update` is stored in `AgentChatStore.usage` but never
  shown. Add a small ring in the composer's controls row (used / size) with a menu that
  shows the tokens.
- **Mode selection.** `current_mode_update` is parsed, but the composer has only Model and
  Effort (`ChatComposer.modelPill`). There is no mode switch, such as Plan or Ask versus
  Code. Add a Mode section to the same menu when the agent sends modes.
- **Plan / progress.** Plan entries are stored, and the transcript shows checklists. There
  is no pinned plan progress (for example `3 / 5`) above the composer while a turn runs.
- **Waiting for Face ID.** See item 11.
- **Fork, Rename, Archive, Open terminal and dictation** are still placeholders
  (`verify/chat-feed.md` known gaps).
- **Live checkpoints and folder listings.** There is no API (`verify/acp-parity.md`).
- **Image viewer for tool images.** The `connection-settings.png` content block is shown as
  an inline image only. I found no full-screen zoom from the transcript.

## What I could not capture

- **The "Waiting for Face ID…" state.** Mock auth resolves Allow instantly.
- **The software keyboard during typing in the recording.** `axe type` uses HID, so iOS
  hides the software keyboard. Only the first-focus frame shows it (`chat-empty-keyboard.png`).
- **Light and AX5 for the chat, diff and artifacts.** I captured them only for the Feed,
  for lack of time.
- **The long-transcript scroll video.** The `-CmuxMobileDemo` driver stalled (item 22). Static
  frames of the 2 000 pt transcript exist.
- **Artifact previews other than code** (HTML, image, PDF, video). They are not reached
  through this session's mock references.
- **A Production build.** It was not reviewed.
