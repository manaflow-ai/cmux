# Agent chat, Feed and diff viewer: verification

Branch `feat-cnx-ios-chat`, 2026-10-12. Modules: `CmuxMobileMarkdown`, `CmuxMobileDiff`,
`CmuxMobileAgentChat`, `CmuxMobileFeed` (shell edits are limited to `RootView.swift` and `Screens.swift`).

## How it was verified

- `xcodegen generate` and a simulator build (`cmux-next-ios/build/dd`).
- Headless simulators, iPhone 17 Pro, dark mode: `cmux-mobile-chat-ios26` (iOS 26.5) and `cmux-mobile-chat-ios27` (iOS 27.0).
  Simulator.app was never opened.
- `verify/record-chat-feed.sh <udid> <label> [seconds]` builds, installs, records with
  `simctl io recordVideo`, launches with `-CmuxMobileDemo chat-feed`, and splits frames with ffmpeg.
- The DEBUG demo driver (`CmuxMobileFeed/FeedDemoScript.swift`, `CmuxMobileDesign/DemoDirector.swift`)
  sends commands through each screen's own code paths. It scrolls the Feed and expands
  Show more. It injects a live event, which shows the "1 new" pill, then answers a
  three-item AskUserQuestion inline and sends an inline reply. It opens an event in its
  agent tab and types and sends a prompt. The mock then streams a full turn: thinking,
  grouped reads and a search, a plan, two edits with diffs, `swift test`, and a permission
  request, which the driver allows. A two-item question follows, which it answers. A third
  edit and a final answer with a table, code and display math end the turn. Last, the
  driver scrolls the transcript, opens the diff file view, expands hidden context, toggles
  Split and back, marks the file viewed, goes back, and opens the Changes list.
- Unit tests (Swift Testing, `Tests/CmuxMobileAgentChatTests`) cover the markdown block parser,
  inline-math detection, unclosed display math, line and word diff, the unified-diff parser,
  ACP `tool_call` decoding, tool wording, and an instant full mock turn through
  `AgentChatStore`. Result: 8 passed on the iOS 26.5 simulator
  (`xcodebuild test -scheme CmuxMobileKit-Package -only-testing:CmuxMobileAgentChatTests`).
  `nx-remote` could not reach `cmux-lawrence-2` (DNS, already in REPAIR.md), so the tests
  ran on the local simulator.

Evidence is git-ignored, in `verify/evidence/2026-10-12/chat/`:

| Path | What |
| --- | --- |
| `ios26/demo.mp4`, `ios27/demo.mp4` | Full demo recordings (about 66 s and 70 s) |
| `*/frames/` | 2 fps frame split |
| `*/sheets/` | Contact sheets (1 fps and 0.5 fps) used for review |
| `ios26/stills/all.png` | 14 key states |
| `compare/*.png` | Side by side with the references |

## Comparisons (SPEC 6.10, 8.3, 12.3)

| Check | Reference | Result |
| --- | --- | --- |
| Code card, table bleed, answer action row | `chatgpt-17-diff-table-stream` | Match: card radius, header with language and copy, mono body, table scrolling horizontally past the margin, icon row with duration. Gap: our table row hairlines are fainter than ChatGPT's. |
| Composer running (stop), collapsed "Follow up" | `grok-05-streaming-code`, `chatgpt-16` | Match: glass capsule, `+`, mic, white stop circle; it expands to the card with the model pill when focused (`Opus 5.5 Medium`, `claude-05`). |
| User bubble, answer actions | `claude-09-chat` | Match: gray bubble on the right, no assistant bubble, icon row. |
| Feed density | `chatgpt-30-scheduled` | X-style rows with full-bleed hairlines, chips row, filter circle. |
| Inline diff colors | `chatgpt-17` | Text-only add/del colors in transcript snippets; row fills only in the viewer (SPEC 6.8). |
| Tool rows, permission, question, plan | none captured; T3 Code and Cursor research | Composer replaced by the stacked permission bar (Allow once / Always / Deny / Reply instead). The card collapses to "Allowed once ..." when resolved. Questions page "1 of N" with Next and Answer, then collapse to "You answered" bubbles. |

## Animations checked frame by frame

- Permission bar arrival: 16 pt rise plus fade; the resolved card collapses into a summary row.
- Question paging slides between items; the answered summary crossfades in.
- Show more: the cell height animates with `smooth` while the web view stays laid out at full height and only the clip changes, so text never reflows mid-animation.
- Jump-to-bottom appears when scrolled more than 80 pt up, with a pulsing ring while streaming.
- Streaming: new blocks fade in over 0.15 s; text inside a block appears as it arrives, without per-word fades. Display math shows TeX source until the closing `$$` arrives. This fixed red parse errors seen in the first recording.
- Diff: split and unified switch with a crossfade. Hunk expansion inserts rows. Marking a file viewed collapses it.

## Fixes made from the recordings

1. Primary fills used `Color.primary`, which renders vibrant gray inside glass. The new `cmuxMobileAccent` token makes "Allow once" and the send/stop button solid white.
2. The quote-bubble tail was drawn into the same path as the bubble and became a hole. It is now a separately filled shape.
3. The diff viewer state was recreated on re-init, and lazy rows kept the old layout, so Split did not show. Fixed with `@State` and an identity tied to the layout.
4. Recycled Feed web views briefly painted their previous body over the next cell during fast scrolls. The view is now hidden until the new body renders.
5. Wide display math is scaled to fit the column, since web views do not scroll.
6. Feed permission buttons were truncated ("Allow on…"); they now use compact labels.

## Performance notes

- Feed bodies use pooled `WKWebView`s: 6 prewarmed views, one shared `WKProcessPool`, and content swapped by a JS call, never a page load. Heights are measured off screen by the prefetcher and cached by content, style and width.
- The Animation Hitches template is not supported on the simulator ("Hitches is not supported on this platform"). A hitch number needs a device run.

## Known gaps

- On the first launch, cells whose height has not been measured can show a blank gap for about 0.5 s while the web view pool warms. Later scrolling uses cached heights.
- A long programmatic scroll to the top of the Feed can show a frame of estimated heights.
- Feed swipe actions (Read / Mute) are not built, because the Feed is a `LazyVStack`, not a `List`. The context menu and the `...` menu offer the same actions.
- Fork, Rename, Archive and Open terminal were removed (b5bfa06): the link has no calls for them. Dictation uses the keyboard's own mic; Camera shows only on devices with a camera. (Updated 2026-10-14; the design loop in `design/chat-feed/` supersedes this page.)
- Data is mock only (`MockAgentSession`, `FeedStore.mockItems`). The real `AgentSessionSource` over the `acpmux` link service comes next.
- Subagents, checkpoints, handoff and image viewer from the Mac ACP UI are modeled only as far as the ACP types allow. They have no UI yet.
