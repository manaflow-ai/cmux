# Agent chat, diff, artifacts and Feed: round 1 review

Fresh designer review, 2026-10-14, of `origin/feat-cnx-ios` at `232651ae0d94`, merged into
`feat-cnx-ios-design-chat`. I did not change app code. I re-checked every SPEC item with my
own captures. The round 1 captures in `round1/` were treated as claims, not evidence.

**Verdict: NOT signed off.** The round 1 blockers are fixed: the diff gutter is pinned, lines
are full width, and wrap heights are correct. Four accessibility-size and legibility defects
remain (F1 to F4).

## Setup

- `xcodegen`, then Debug and Production simulator builds (`-jobs 4`, derived data
  `/tmp/cmux-mobile-chat-review-dd`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
  Both built. The xcframework is identical to the one in `feat-cnx-ios`.
- One headless iPhone 17 Pro (iOS 27.0, 402 x 874 pt) named `cmux-mobile-chat-review`, deleted at
  the end. Simulator.app was never opened. Input came from `axe` HID, and frames are AX
  frames in pt. I did not pair with a Mac, use the E2E rig or make model calls.
- Every Debug capture is **mock (layout only)**: `CMUX_MOBILE_MOCK_AUTH=1` with the
  `-CmuxMobileDemo chat-feed` driver, sometimes with `-CmuxMobileDemoHold chat|diff` and
  `-cmuxMobile.dev.slowFaceID YES`.
- Screenshots in `round1-review/` are 402 x 874 (1 px = 1 pt) unless the name says `crop`.
  Videos are 402 px wide H.264.
- Load: `driver-run-dark-mock.mp4` started at a 1-minute load of 30.3 and ended at 21.6. The
  `-CmuxMobileDemo` driver uses fixed pauses, so the video is not timing evidence.
  `diff-hpan-gutter-pinned-dark-mock.mp4` was recorded at a load of about 90. Use it only
  for layout (gutter pinned), not for frame pacing.

## Per item (SPEC numbering)

| # | Item | Result | Evidence and measurement |
| --- | --- | --- | --- |
| 1 | Diff: full-width lines, gutter pinned while panning | **PASS** | `diff-hscroll-gutter-pinned-dark.png`, `diff-hpan-gutter-pinned-dark-mock.mp4`. Row backgrounds are 1005 pt wide (AX `x94 w1005`), so the longest line sets the width. The 2-column number gutter and the +/− column stay at x 0 to 94 after four pans. A `Horizontal scroll bar, 4 pages` is exposed. No foreign fragments. At AX5 too: `diff-ax5-hscroll-gutter-pinned-light.png` |
| 2 | Wrap mode heights and hanging indent | **PASS** | `diff-wrap-hanging-indent-dark.png`, `diff-wrap-bottom-no-overlap-dark.png`. `return MacLink(stream: channel)` (old 18) and `switch transport() {` (new 17) no longer overlap. Continuations align under the first non-space character (lines 9, 16, 21, 24). Long identifiers break mid-word (`WireGuardDialer(signalin` / `g:`), which is acceptable for code |
| 3 | Feed at AX5 | **FAIL (partly)** | The source line wraps (`cmux · 2m` on its own line) and `Show more` no longer overlaps. However, the filter chips stay 36 pt high (AX `Needs you, 2` `w301 h36`) while their text is about 48 pt. Glyphs spill out of the capsule, the `y` descender is cut, and the `2` badge sits on the `u` and is cut by the fade. See `feed-ax5-chips-overflow-capsule-light.png` and `feed-ax5-chips-crop-light.png`. Round 1's own `largest-text/01-feed-ax5-source-wraps.png` shows the same defect. → F1 |
| 4 | Soft top edge in both chat placements | PASS | The transcript fades under the floating title (`chat-turn-done-collapsed-composer-dark.png`, `chat-waiting-for-face-id-dark.png`) |
| 5 | No blank gap while streaming | PASS (2 fps sample) | `chat-stream-2fps-contact-sheet-dark.png` (30 to 42 s of the driver run). No inserted gap between blocks while the answer, plan and diffs stream |
| 6 | Hide unmatched markdown markers mid-stream | Not observed | No literal `*` or backtick appeared in the 2 fps sample. That is not enough to prove the fix, but nothing regressed |
| 7 | Code and tables scroll horizontally | PASS | The Bash block and the table scroll inside their cards with a trailing fade (`chat-turn-done-collapsed-composer-dark.png`; table AX `Horizontal scroll bar`). The Feed code no longer soft-wraps |
| 8 | Checkboxes for any-of questions | PASS | Chat `Choose any` uses `Square` images (`chat-question-checkboxes-plan-pinned-dark.png`). Feed step 2 also uses `Square` / `Selected` (`feed-question-2of3-partial-before-relaunch-dark.png`). Single-select steps keep circles |
| 9 | One rule: auto-advance, no Next on single-select | PASS | Tapping `Release candidate` moved straight to `2 of 3`. Step 1 has no Next. The multi-select step has `Back` (44 x 44) and `Next` |
| 10 | Feed partial answers and read flags survive relaunch | **PASS** | I selected `Feed inline answers` on step 2, then relaunched: `2 of 3` with the same box `Selected` (`…before-relaunch…` → `…after-relaunch…`). I opened the `ship it to staging` event, then relaunched: no `Unread` before it, while untouched events kept theirs (`feed-read-flag-kept-after-relaunch-dark.png`) |
| 11 | "Waiting for Face ID…" state and DEBUG delay | **PASS** | With `-cmuxMobile.dev.slowFaceID YES`, the primary button became a spinner and `Waiting for Face ID…`. `Always allow…` was disabled and `Deny` stayed enabled (`chat-waiting-for-face-id-dark.png`). The switch also exists in Settings → Developer. It is compiled out of Production: `DeveloperOptions.mockFaceIDDelay` is `.zero` outside DEBUG |
| 12 | Title from the first prompt | PASS | A new Claude chat with the prompt `Summarize the token rotation plan for the relay worker and list risks` was titled `Summarize the token rotation plan for…`, cut at a word inside 40 characters (`chat-new-title-from-first-prompt-dark.png`). I could not test `session_info_update` in mock |
| 13 | 44 pt targets for the listed controls | PASS for the listed controls | Send and Stop 44 x 44, Context 44 x 44, question Back 44 x 44, Feed `Show more` 80 x 44, Event actions 44 x 44. In code, `Show N more lines` and `Reply instead` have `minHeight: 44`. **Still under 44 (not in the round 0 list):** see F5 |
| 14 | "Show 1 more line" | PASS | `ToolViews.swift:280` |
| 15 | SF Symbol for the permission title | PASS | `hand.raised.fill` in `cmuxMobileWarning` (`CardViews.swift:86`). In the capture it is a yellow symbol, not the emoji |
| 16 | Tail truncation of commands | PASS | `Ran swift test --filter LinkDial…`, `Allowed once cargo test -p cmux-mobile-link…`. I did not verify the full command on tap |
| 17 | Empty new chat | **FAIL (partly)** | The placeholder is `Ask Claude` (pass). The glyph is still the generic `Sparkle Star`, not the Claude asterisk (`chat-new-empty-sparkle-glyph-dark.png`). → F6 |
| 18 | Stop disabled while idle | PASS | `Stop agent` is `DISABLED` in the More menu after the turn (`chat-more-menu-stop-disabled-idle-dark.png`) |
| 19 | Artifacts thumbnails, chip y, chip fade | Not re-captured | Out of time. Carry over to round 2 |
| 20 | Split only at 700 pt or wider | PASS | Diff options at 402 pt shows only Wrap lines, Hide whitespace and Show viewed files (`diff-options-no-split-at-402-dark.png`). `DiffLayout.swift:103` is `width >= 700`. The driver forces Split through `diffSetSplit(true)`, but the phone UI never offers it |
| 21 | Feed `1 new` pill | PASS (driver video) | The pill sits below the chips with a glass background (`driver-run-dark-mock.mp4`, around 6 s) |
| 22 | Driver runs end to end and has no keyboard tip | **FAIL (partly)** | The driver now runs the whole script: Feed, question, reply, chat turn with permission and question, diff, Changes. Problems: (a) The `Speed up your typing by sliding your finger` tip covers the composer for about 4 s mid-run (`chat-keyboard-tip-covers-composer-dark.png`). (b) On a fresh simulator, the driver sits on `Choose a space` for its whole run and does nothing. I had to pick Personal first. → F7 |

### ACP web UI parity

| Feature | Result | Evidence |
| --- | --- | --- |
| Context meter | **Present, but FAIL on legibility** | A 44 pt `Context used` button with the value `24 percent, 48K of 200K tokens`. Its menu shows `48K of 200K tokens` and `24% used`. The glyph is a grey 24 % arc that starts at 12 o'clock, which is the shape of an activity spinner (`chat-context-ring-zoom-reads-as-spinner.png`). In the composer it reads as "loading". → F2 |
| Mode menu (`session/set_mode`) | PASS | The composer menu has Effort, then a Mode section (Auto, Plan, Accept edits, Manual), then Model (`chat-composer-menu-mode-section-dark.png`). Picking Plan changes the pill to `Opus 5.5 Plan Medium` (`chat-mode-plan-in-pill-context-ring-dark.png`). `ChatComposer.swift:259` sends `session/set_mode`. The title menu repeats Mode in the reverse order (Manual … Auto, `chat-title-menu-mode-reversed-order-dark.png`). → F8 |
| Pinned plan progress | PASS | The pinned bar above the composer reads `Run the Swift and Rust link tests 2 / 4`. It reaches `Plan complete 4 / 4` at the end of the turn (driver video) |
| Image viewer | PASS | Tapping `connection-settings.png` (200 x 150) opens a full-screen black viewer with ✕, the title and Share (`chat-image-viewer-dark.png`). Swiping down dismisses it. Double-tap zoom did not take with two `axe` taps, possibly because of HID timing. The code advertises pinch and double-tap |
| Removed Fork, Rename, Archive and Open terminal | **PASS: nothing dead remains** | The chat More menu has only Files and artifacts, Share transcript and Stop agent. The title menu has Files and artifacts, Agent edits, Subagents (4), Checkpoints, Continue in…, Copy session ID and Mode. `grep -rnw -i 'fork\|rename\|archive\|openTerminal\|dictation'` over CmuxMobileAgentChat, CmuxMobileFeed, CmuxMobileShell and CmuxMobileModel finds only workspace rename (a real API), the Feed `Done` swipe tint named `archive` and a comment about the mic. The Production binary has no `CmuxMobileDemo`, `chat-feed` or `MockAgentSession` strings. Stale docs remain (not app code): `design/SPEC.md:48` says "Dictation lives on the mic glyph", and `verify/acp-parity.md:92` lists Archive in the chat More menu |
| Production build | PASS | `dev.cmux.mobile.prod`, launched with `CMUX_MOBILE_MOCK_AUTH=1 -CmuxMobileDemo chat-feed -cmuxMobile.dev.mockData YES -cmuxMobile.dev.slowFaceID YES`, shows the normal sign-in (`production-ignores-mock-and-demo-dark.png`) |
| Dark and light | PASS for color | Chat, Feed and diff render correctly in both (light captures at AX5). No dark-only colors |

### New findings at the largest text size (AX5, light)

- **Chat:** at the bottom of a transcript that ends in a question card, about 367 pt of blank
  space sits between the card (bottom at y ≈ 390) and the composer (top at y ≈ 757). At the
  default size the card sits on the plan bar and composer with no gap. See
  `chat-ax5-bottom-gap-light.png`. → F3
- **Diff file header:**
  - The `M` badge is a fixed 20 pt box, so the AX5 glyph spills out of it and is cut.
  - The path collapses to `…ft` (AX `w81`), so the file name cannot be read.
  - `+15 −6` dominates the row.
  - Mark viewed and File actions stay 32 x 32.
  - See `diff-ax5-header-badge-clipped-path-collapsed-light.png` and
    `diff-ax5-header-crop-light.png`. → F4

## Fix list for round 2

**Must fix (blocks sign-off):**

- **F1. Feed chips at AX sizes.** Let the chip height follow the text (`minHeight: 36`, not a
  fixed height), or cap chip text at `.accessibility1` with `dynamicTypeSize(...
  .accessibility1)`. The count badge must sit inside the capsule. The trailing fade must not
  cover the last visible chip's badge. Recapture `feed-ax5-chips-*`.
- **F2. Context meter legibility.** It must not look like a spinner. Show the number in the
  ring (`24`, caption2 monospaced digits), or use a filled pie or a gauge
  (`Gauge(...).gaugeStyle(.accessoryCircularCapacity)`). Use the tint when usage is over
  80 %. Keep the 44 pt target.
- **F3. Chat bottom gap at AX5.** Find the bottom inset that grows with Dynamic Type, such as
  a reserved permission or question dock height or a padding that scales. The last row must
  rest just above the plan bar or composer at every text size.
- **F4. Diff file header at AX sizes.** Cap the header at `.accessibility1`, or stack it as
  badge + file name on line 1 and the counts on line 2. The badge must grow with its glyph,
  and the file name must always be readable. Give Mark viewed and File actions 44 pt hit
  areas.

**Should fix:**

- **F5. Hit targets still under 44 pt:**
  - Message actions Copy, Share, Retry and More: 32 x 32.
  - Feed Reply, Open, Copy and Share: 32 high.
  - Feed question `Next`: 77 x 40.
  - Diff header `Mark as viewed` and `File actions`, and the Changes list `Mark as viewed`:
    32 x 32.
  - Nav `More` and `Diff options`: 28 x 36.
  - Add a `contentShape` or a frame to reach 44.
- **F6. Empty new chat glyph.** Replace `sparkle` with the harness glyph (the Claude asterisk
  or the Codex mark), as the Feed does.
- **F7. Demo driver robustness.**
  - Select the Personal space (or skip `Choose a space`) when it appears, so the driver runs
    on a fresh install.
  - Dismiss the keyboard swipe-typing tip before typing. The tip is the system's
    first-keyboard tip; the simplest fix is to type through the director without raising
    the keyboard, or to tap Continue.

**Polish:**

- **F8.** Mode order differs between the composer menu (Auto → Manual) and the title menu
  (Manual → Auto) because the menu order is automatic. Use `.menuOrder(.fixed)`, or keep Mode
  in one place.
- **F9.** The collapsed composer shows `Follow up`, but its AX label and the expanded
  placeholder say `Reply to Claude`. Use one string.
- **F10.** An off-screen `Close <session title>` button (30 x 30 at x 372, y 0) is in the AX
  tree of a workspace chat tab. VoiceOver reaches it, but sighted users cannot. Hide it, or
  give it a visible place.
- **F11.** The scroll-to-bottom `↓` button sits on the title of the card below it
  (`Created transport-report.html`, `chat-transcript-image-dark.png`). Give it a glass
  background and 8 pt clearance above the composer.
- **F12.** Remove the stale dictation and Archive mentions from `design/SPEC.md:48` and
  `verify/acp-parity.md:92`.
- Carry over SPEC 19 (artifacts) and a long-transcript scroll video at load < 40 to
  round 2.

## Not verified here

- Persistence of a chat tab created on the phone across relaunch. In mock, the tab list is
  in memory (`MockWorkspaceCreationBackend`), and the real Mac owns tabs. After relaunch the
  new Claude tab was gone, which is expected for mock. Confirm with a paired Mac in E2E.
- Item 6 (markdown markers mid-stream) beyond a 2 fps sample, and the ACP title from
  `session_info_update`.
- Artifacts (SPEC 19).
