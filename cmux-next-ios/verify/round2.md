# Round 2: the remaining known defects

Branch `feat-cnx-ios-round2`, 2026-10-13. This pass fixes the open items in
`e2e-live.md`, `chat-dogfood.md`, `keyboard.md` and `navigation.md`.

## How it was run

- **Simulators:** headless iPhone 17 Pro `cmux-mobile-r2-ios26` (iOS 26.5) and
  `cmux-mobile-r2-ios27` (iOS 27.0), dark appearance, Debug build from
  `verify/build.sh`. Simulator.app was never opened.
- **Keyboard:** every keyboard check used the software keyboard. The iOS 27
  simulator was erased once after `axe type` attached a hardware keyboard,
  then reinstalled before its keyboard runs.
- **Input:** real HID taps, long presses and edge drags came from `axe`, with
  the helpers in `verify/chatdog.sh`, `verify/swipe-rec.sh` and
  `verify/record-keyboard.sh`.
- **Review:** `simctl io recordVideo` recorded each fix. The frames were
  split and reviewed at 4 to 30 fps.
- **Live run:** `mini-cmuxs-mac-mini-2`, user-local under `~/cmux-next-ios-e2e/r2`,
  ran `verify/scripts/e2e-mac.sh` with these parts:
  - `cmux-tui`;
  - `acpmux` with the credit-free `e2e_agent.py`;
  - `cmux-mobile-host` rebuilt from this branch.

  The Mac ran in the personal space as "mobile r2 mini 2". It signed in with
  the `CmuxAuthRuntime` DEBUG dev credential. The token stayed in a 0600
  file on the mini and was never printed. Everything was stopped afterwards,
  and the `r2` folder (including the token) was deleted.
- **Evidence:** git-ignored, in `verify/evidence/2026-10-13/round2/`. Live
  evidence is under `live/` and keyboard evidence under `kbd/`.

## Results

| # | Defect | Root cause | Fix | Verified |
| --- | --- | --- | --- | --- |
| 1 | Feed empty after a relaunch (live) | `_acpmux/watch` reports only new events, and the store started empty on every launch | **Persist:** `FeedArchive` saves finished turns and failures, with read, done and replies, per account in Application Support. Open asks are not saved, because the Mac re-reports them. **Re-hydrate:** on every connection (`sessionsLoaded`) and tree update, each session's last finished turn becomes its item. The item is keyed by `turnId` (live and history share one id) and dated `lastTurn.endedAt`. `mergeHistory` keeps what the person did. `upsert` no longer resurrects items marked done | Live, iOS 27 (`live/feed-row.png`): a turn finished before the first launch shows. A live turn arrives. After a relaunch, the archive shows both at 2 s, before the link. A turn finished while the app was closed is added on connect |
| 2 | Files and Links split wrapped paths | The extractor read the byte stream. The shell echo and the reattach replay break a long line into rows | On open, and while the sheet is open, the list is rescanned against Ghostty's screen text (`ghostty_surface_read_text` over the whole screen joins soft-wrapped rows). A row that fills the width and ends in a path character also joins the next row (`logicalLines`). The whole reference replaces its start, middle and end pieces | Live, iOS 27 (`live/fl-after2`, `live/fl-preview`): a 3-row command and 3-row output list one file and one folder, and the file previews from the Mac. The first live pass found a leftover middle piece, which was then fixed (`aMiddlePieceIsReplacedToo`) |
| 3 | Edge swipe did not pop the diff file screen | `EdgeSwipePriority` made the 2D code scroller wait for the pop, but the pop still yielded and the code bounced | For an edge touch on a pushed screen, a horizontal scroller at its leading edge sits that touch out (its pan is reset). It has nothing to scroll back to | Interactive pop on both simulators (`diffswipe-before` vs `diffswipe-after`, `diffswipe-ios27`). Horizontal scrolling from mid-screen still works (`diff-hscroll-after`) |
| 4 | Tool group summary showed old and new text overlapping | When the second call arrived, the row's id changed from `c-<id>` to `g-<id>`. The transcript removed one row and inserted another, crossfading "Read lib.rs" over "Read 2 files" (`tg30-tile.png`) | A run keeps the id of its first call. The single-row and group views and the running and finished labels swap with `.transition(.identity)` | 30 fps frames (`tga30-tile.png`): "Reading lib.rs" becomes "Read 2 files" in one frame, with no overlap |
| 5 | New workspaces opened with the keyboard down | Only `createTab` focused new chats | `WorkspaceCreator` marks a created workspace (`AppStore.requestFocusOnOpen`). Its first page focuses the agent composer or the terminal composer. The mark holds while the placeholder becomes the Mac's tab. New terminal tabs focus too. **Terminal decision:** keyboard up, because a fresh shell's next step is a command and Blink, Termius and Prompt raise the keyboard for a new session. Existing workspaces still open with the keyboard down | iOS 26 (`wsnew-terminal-after`, `wsnew-claude-sheet`): terminal and Claude workspaces open with the keyboard up. In the live run, a new workspace opened with its composer focused (`live/live-wsnew`) |
| 6 | Tab composer lagged the finger at the start of a drag dismissal | Not reproduced on this branch | No change to `CmuxTabsKit`. The per-frame trace shows the TabsKit composer 8.00 pt above the drawn keyboard on every drag frame on both simulators, from the first moving frame (`kbd/ios26-tab-before`, `kbd/ios27-tab-before`). The pixel measurement gives the same 2.3 to 11.3 pt spread as the pushed chat's UIKit-pinned composer (`kbd/ios26-chat`), which is video-timing noise. Moving the accessory onto a UIKit keyboard guide would change the package shared with the terminal key bar and bring back the iOS 27 guide quirk, without a measured gain | Trace and pixels, both simulators |
| 7 | Artifacts listed links before edited files; answer icons fixed at 16 pt | The list sorted by first appearance | Relevance tiers, newest first in each: edited, created or attached, then read, then other files, then links. `IconActionLabel` scales the glyph and its target with Dynamic Type (16 in 32 at Large) and is shared by Copy, Share, Retry and More. The duration stays on one line | `artifacts-order`, `icons-ax2` (accessibility extra large) |
| 8 | Composer gap above the keyboard | — | Measured from pixels, the gap between the card's bottom edge and the keyboard's top edge (reference pack at 1.54 px/pt): Claude `claude-05` 7.1, Grok `grok-01`/`grok-03` 7.1, ChatGPT `chatgpt-01` 13.0, Messages 16. cmux-next-ios measures 8.0 (`gap-tab`). The AI apps cluster at 7, and 8 is within one measurement step. The code is unchanged, and SPEC 2.3 records the measurements | `gap-tab.png` |

## Tests

Each logic test failed (red) on the old behavior before its fix (green).
The last column lists the red result for each one.

| Test | Covers | Red before the fix |
| --- | --- | --- |
| `ArtifactExtractorTests` (CmuxMobileTerminalTests) | Width joins, a rule row stays apart, start, middle and end pieces replaced, history kept, later output not listed twice | 3 issues; `aMiddlePieceIsReplacedToo` 1 |
| `FeedHistoryTests` (CmuxMobileLiveTests) | Hydration on connect, no duplicate on a live `turn_result`, done kept across merge and upsert, archive round trip without asks | 4 issues |
| `ToolRunIdentityTests` (CmuxMobileAgentChatTests) | A run's row id is stable | 1 issue |
| `strongestReferencesComeFirst` (ParityTests) | Relevance order | 2 issues |
| `aCreatedWorkspaceOpensReadyToType` (CmuxMobileModelTests) | Focus request | New API, so it did not compile |
| `newWorkspacesAndTabsOpenReadyToType` (CmuxMobileWorkspacesTests, iOS) | Focus request | New API, so it did not compile |

- `swift test` in `CmuxMobileKit` (macOS) passed every suite.
- `xcodebuild test -scheme CmuxMobileKit-Package` on `cmux-mobile-r2-ios27` passed every suite
  (`TEST SUCCEEDED`).
- `CmuxTabsKit` is unchanged.

## Still open

- With the composer expanded at large Dynamic Type sizes, the transcript can
  sit left of its margin (`icons-ax2`). This is the known item from
  `navigation.md`.
- A scroller at its leading edge also sits out an edge touch that moves
  left, for example a table that starts within 28 pt of the edge. Such a
  swipe does not scroll the table.
- Stale Macs: every live run registers a Mac ("mobile r2 mini 2") that stays in
  the personal space. There is still no forget action.
