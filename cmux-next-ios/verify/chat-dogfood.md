# Agent chat dogfood: defect log

Branch `feat-cnx-ios-chatdog`, 2026-10-13. The pass covers the agent chat
(`CmuxMobileAgentChat`), with small fixes in `CmuxMobileMarkdown`, `CmuxMobileDiff` and `CmuxMobileDesign`. The
goal was a chat that feels like ChatGPT, Claude, Grok, T3 Code and Cursor on iOS and
keeps feature parity with the Mac's acpmux web UI (`webviews/src/agent-session/acpmux/`).

## How it was run

- Headless simulators, iPhone 17 Pro: `cmux-mobile-dog-ios26` (iOS 26.5) and `cmux-mobile-dog-ios27`
  (iOS 27.0). Simulator.app was never opened. The build used `verify/build.sh`, and the app
  ran with `CMUX_MOBILE_MOCK_AUTH=1` and mock agent sessions (`MockAgentSession`).
- Every interaction was a real HID touch or keystroke through `axe`: taps, long presses,
  edge drags, swipes and typing. No demo driver was used. `verify/chatdog.sh` holds the
  helpers. Source it, then use `gochat`, `tap x y`, `tapl LABEL`, `ui` (accessibility
  tree with frames), `shot`, `recstart`/`recstop`, `frames` and `row` (side-by-side strips).
- Recordings were made with `simctl io recordVideo` and split into 2 to 6 fps frames. The
  frames were reviewed next to the matching reference in
  `~/Downloads/cmux-native-references`: `claude-05` and `claude-09`; `chatgpt-16`, `-17`,
  `-18`, `-19`, `-21` and `-25`; and `grok-01`, `-05` and `-06`.
- Logic fixes have Swift Testing coverage in `Tests/CmuxMobileAgentChatTests/ChatDogfoodTests.swift`:
  `WorkingIndicatorTests`, `ReplyInsteadTests`, `StopWhileWaitingTests`,
  `ComposerMentionTests` and `MenuTimestampTests`. Each regression was committed red before
  its fix. `swift test --filter CmuxMobileAgentChatTests` on macOS ran 24 tests in 10 suites, and all
  passed. `nx-remote` could not resolve `cmux-lawrence-2`, which REPAIR.md already lists, so
  the tests ran locally.
- Evidence is git-ignored, in `verify/evidence/2026-10-13/chatdog/`. Stills are `<name>.png`
  (full size) and `<name>.s.png` (900 px). Strips are `r1.png` to `r24.png`. Recordings are
  `turn1.mp4`, `turn2.mp4`, `reply.mp4`, `defer.mp4`, `first.mp4`, `newchat.mp4` and
  `i27-turn.mp4`, with `*-frames/` beside them.

## Scenarios covered

These were checked on iOS 26.5, and the main turn was repeated on iOS 27.0:

- Opening a chat with history.
- The first prompt in a new tab session.
- A long streamed turn with thinking, grouped reads and searches, a live plan, two edits
  with inline diffs, a command, a permission request, a two-item AskUserQuestion, a third
  edit, and a final answer with a heading, lists, a task list, a table, code, inline and
  display math, and links.
- Permission requests: Allow once, Deny, Reply instead, and a permission that arrives while
  you type.
- Single and multi-select questions.
- Stop during a permission and during a question.
- Sending while the agent streams (queued messages, Steer).
- Attaching photos and sending them.
- The model and effort menu, the `+` menu, slash commands and `@` mentions.
- The bubble context menu and the answer row.
- Jump to bottom and scrolling through history.
- The title menu and the More menu.
- Changes, a file diff and back.
- Files and artifacts, subagents, a subagent transcript, checkpoints, and Continue in.
- The empty state.
- Workspace tab mode.
- Light mode and accessibility-extra-large Dynamic Type.
- VoiceOver labels, read from the accessibility tree.

## Defects found and fixed (32)

| # | Area | Defect (before) | Fix (after) | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Composer | Tapping the collapsed "Follow up" capsule did nothing. Focus went to a text field that only exists once the composer is expanded, so you could not start a follow-up. | The tap expands the composer, then focuses the field. | `typed1` (before) → `focus1` |
| 2 | Markdown table | Wrapped cells kept a one-line row height, so text ran into the row separators. The grid measured cells at their ideal single-line width inside the horizontal scroller. | `TableCellLayout` reports the height at the capped column width. | `crop-table` → `tbl2` |
| 3 | Markdown table | Cells were vertically centered. ChatGPT aligns cells to the top. | `Grid(alignment: .topLeading)` | `r7` |
| 4 | Inline code | The 16 % fill drew heavy full-height blocks that merged across lines. | Uses the 8 % `cmuxMobileFill`. | `crop-table` → `mono1` |
| 5 | Inline code | The font was fixed at callout size, so it looked larger than the plan steps and table cells around it. | No explicit font. Text draws the code in the monospaced variant of the surrounding font. | `r14` → `mono1` |
| 6 | Working label | "Working · 5s" sat under a running tool row that already showed a shimmer and a spinner. | `needsWorkingIndicator`: hidden while the last row shows its own progress. | `r1` (s3) → `r4` |
| 7 | Working label | "Waiting for permission" and "Waiting for your answer" repeated the card above them. | Hidden while a permission or question card waits. | `r2`, `r3` → `r5` |
| 8 | Permission bar | "Always allow cargo test in this works…" was truncated. | Bar buttons wrap to two lines and grow. | `r1` → `r4` |
| 9 | Question card | A disabled Answer button showed on page 1 of 2 next to Next. | Answer shows only on the last page, or once every item is answered (SPEC 6.6). | `r2` → `r22` |
| 10 | VoiceOver | The shimmer read its text twice ("Waiting for your answer, Waiting for your answer"). | The highlight layer is hidden from accessibility. | accessibility tree |
| 11 | Edited files card | File names were truncated ("TransportKi…") while the folder kept its room. | Names take layout priority, and counts never wrap. | `r3` → `tbl2` |
| 12 | Reply instead | Tapping it left the composer collapsed and unfocused. | The composer opens focused with "Tell Claude what to do instead". | `ri1` |
| 13 | Reply instead | The reply queued behind a permission nobody could answer anymore, because the bar was gone. The agent waited forever. | Sending denies the request (reject once) and sends the text as guidance. Leaving the composer empty brings the choices back. | `r5`, `ReplyInsteadTests` |
| 14 | Permission | A request that arrived mid-draft replaced the composer under your fingers. | The draft stays and queues as a follow-up (it does not answer the request). The card shows an "Allow or deny…" button, and the choices return when you leave the composer. | `r10`, `defer.mp4` |
| 15 | Queue | Queued messages were hidden while the permission bar showed. | `QueuedPromptsView` sits above the composer or the bar. | `r11` (q4) |
| 16 | Stop | Stop during a permission or question did nothing. The mock never woke the waiting turn. | Cancel resolves outstanding requests and ends the turn. | `StopWhileWaitingTests` |
| 17 | Stop | A stopped turn left an interactive question card, so you could still answer it. | A turn that ends cancels its open questions and permissions. | `r12` → test |
| 18 | Model menu | The "Model" and "Effort" section headers were missing, because inline pickers drop them. | Checkmark buttons in titled sections. | `r7` → `r13` |
| 19 | Context menus | The header read "Tuesday 3:03 PM" for a message sent today. | "Today, 3:03 PM", "Yesterday, …", then a weekday, then a date (ChatGPT `chatgpt-19`). | `r8`, `MenuTimestampTests` |
| 20 | Mentions | There were no `@` file mentions (acpmux `MentionMenu`). | Typing `@` offers files the session referenced, written as `@path ` and quoted when the path has a space. The `+` menu gains "Mention a file". | `mention1`, `ComposerMentionTests` |
| 21 | Empty state | "What should Claude do?" sat pinned to the composer, from the bottom anchor plus a fixed 220 pt top pad. | Centered in the visible transcript. | `r13` → `newchat1` |
| 22 | New tab (mock) | A new Claude tab replayed the demo history, so its empty state could never be seen. | Mock sessions made on the phone ("New session") start empty. | `newchat1` |
| 23 | Workspace tab | The transcript ran under the status bar's clock. Tab mode has no navigation bar to draw the scroll edge effect. | A background fade under the status bar. | `ws-cmux` → `ws-cmux2` |
| 24 | Dynamic Type | At AX sizes the changes card read "1 file… +… Revi…". | Counts stack under the names, and rows grow. | `r16` |
| 25 | Dynamic Type, VoiceOver | The model pill read "Opus… Medi…", and VoiceOver said only "Model". | Effort is dropped when it does not fit. The pill reads "Model, Opus 5.5, Medium". | `r16` |
| 26 | Diff viewer | Tapping a file in Changes from a chat on Home only highlighted the row. It was a value link, and Home's typed path has no destination for it. | Destination links. | `diff2` → `r18` |
| 27 | Diff viewer copy | "1 files changed", "This turn · 1 files" | Singular forms. | `r17` → `r19` |
| 28 | Subagents | Rows that push had no chevron. | Chevron added. | `r20` |
| 29 | Checkpoints | The age was truncated ("31 min…"), and the copy read "1 files". | Branch and head on one line, count and age on the next; singular forms. | `r21` |
| 30 | Sent images | Sent images were 56 pt thumbnails, inset from the bubble's edge by remove-badge padding. | One image shows at 200 × 150, several as 96 pt squares (+N past three), radius 16, aligned with the bubble. | `r23` → `r24` |
| 31 | Mock copy | After Deny, the mock said "Both test suites pass". | The mock text follows the choice. | `r11` |
| 32 | Answer menu | The header used the prompt's time. | It uses the time the answer finished. | — |

## Remaining issues

- The diff file screen ignores the edge back swipe. The 2D code scroller takes the drag
  (`r18`). The back button works. `EdgeSwipePriority` in `CmuxMobileShell/SidebarContainer.swift`
  should cover it, but it does not for this SwiftUI 2D `ScrollView`. This belongs to the
  navigation owner.
- While a tool group runs, its summary ("Read 2 files") briefly shows old and new text on
  top of each other as the count changes (`r24`, left).
- The artifacts browser lists links from the answer before the files the agent edited or
  created. The strongest reference should come first.
- The answer action icons (copy, share, retry, more) stay at 16 pt at AX sizes.
- In light mode, code cards have no 0.5 pt separator border (SPEC 4.6).
- The `+` menu has both "Plan mode" and "Permission mode > Plan", which overlap.
- The Feed cell's context menu header still uses the weekday format. It is owned by the
  Feed, not changed here.
- "Mac offline mid-stream" and "reconnect" were not exercised. The mock session cannot
  drop its link. The live session against a mock ACP agent through `cmux-mobile-host`
  (`verify/live.md`) was not run in this pass. Live attach is `feat-cnx-ios-e2e`'s area.
- `@` mentions offer only files the session already referenced. A full search needs a
  `file.search` channel over the link, the Mac's `git.files.search` (PROTOCOL.md has none
  yet).

## Keyboard (for feat-cnx-ios-kbd)

The simulators had a hardware keyboard connected, so the software keyboard never showed.
Keyboard lift, clipping and interactive dismissal could not be observed in this pass. These
are left for the keyboard owner:

- SPEC 6.2 says the composer is focused when the person tapped "new". "New Claude Chat"
  opens the tab with the composer unfocused (`newchat1`).
- The composer can now open focused from code: `expandOnAppear` (Reply instead) and the
  capsule tap. Both expand first, then set focus on the next run loop turn, because the
  field does not exist while collapsed. Check that the keyboard rides up in one motion with
  this two-step expand.
- When the permission bar replaces a focused composer, the keyboard drops and the bar
  appears. When the choices come back on blur, the reverse happens. Check that both
  transitions stay in lockstep with the keyboard.

## Merging feat-cnx-ios-kbd

`origin/feat-cnx-ios-kbd` was not on the remote during this pass (checked several times).
When it lands, merge it and re-run the scenarios above with `verify/chatdog.sh`. Expect
conflicts in `AgentChatScreen.swift` (the transcript overlay and the bottom stack) and
`ChatComposer.swift` (`expand()`, the queue moving out of the composer).
