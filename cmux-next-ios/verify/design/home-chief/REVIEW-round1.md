# Home and Chief, round 1: designer review

Designer review, 2026-10-14, of the round 1 implementation
(`e2d561fb29`, merged into `origin/feat-cnx-ios` at `9b38033da4`) against
[SPEC.md](SPEC.md). The files in `round1/` are the implementer's claims. Every
result below comes from my own build and captures, in `round1-review/`.

**Verdict: NOT SIGNED OFF.** Both blockers (compose, AX5) pass. Items 2, 7, 8,
10, 11 and 14 pass. Item 3 passes for the phone. Item 6 fails in the one case
the spec was written for: a Codex Chief whose model is "Default". There are
also four smaller defects (F2 to F5), one spec gap (F6) and a note for the
Mac request (F7). The fix
list is short. Round 2 should only need code-level fixes and a recapture.

## How this was checked

- **Build:** Debug simulator build of `origin/feat-cnx-ios` `9b38033da4`
  (`dev.cmux.mobile`). Xcode at `/Applications/Xcode.app`, `-jobs 4`.
- **Simulator:** one headless simulator, `cmux-mobile-home-review2` (iPhone 17 Pro,
  iOS 26.5, 402 x 874 pt). Simulator.app was never opened, and the simulator
  was deleted afterwards. Taps were HID touches through `axe`. I re-ran
  `round1/capture.sh` (its steps match the spec's acceptance walk) four times:
  dark, light, AX5 light and AX5 dark. I also made two compose timing
  recordings of my own.
- **Content:** mock content (`CMUX_MOBILE_MOCK_AUTH=1`), so this checks **layout
  only**. There was no Mac and no pairing, and Chief sent nothing.
- **Accessibility:** `axe describe-ui` trees. Element frames are in points.
  The JSON dumps are in `round1-review/*/`. VoiceOver itself was not turned
  on.
- **Measurements:** full-resolution (3x) PNGs and PIL pixel reads. WCAG
  contrast uses relative luminance. The screenshots in `round1-review/` are
  downscaled to 402 px wide, so 1 px = 1 pt.
- **Load:** the 1-minute load was 38 to 58 during the walks and 22 during the
  second compose recording.

## Results by spec item

| # | Spec item | Result | Evidence and measurement |
| --- | --- | --- | --- |
| 1 | Compose opens Chief with the composer focused (1.4) | **PASS** | `compose-ax.json`: `conversation.composer.text` exists and the keyboard is up. Compose's label is "New Message to Chief" (`home.compose`), and the glyph is `square.and.pencil`. Second run, `compose2-402w.mp4`, at load 22: the push runs 1.50 to 2.07 s, and the keyboard starts at 2.13 s, about 0.07 s after the spring settles. First run, `compose-402w.mp4`, at load 38: a static 0.40 s gap (1.57 to 1.97 s). Both runs use the same code, so the gap is load. Recheck on a device |
| 1.1 | No visible title; chevron-only back button | **PASS** | No "Conversations" text in any Home capture; it is only the AX group label. The agent chat's back button is a chevron alone (`light/10-agent-chat.png`) |
| 1.2 | Rows: workspace title, harness mark, 83 pt | **PASS** | AX: row pitch is 83 pt (302, 385, 468, 552, 635, 718), and the title is at x 83. Titles are the workspace ("cmux", "cmux.com", "cmux-next-ios", …). Avatars use the Claude and Codex marks on `monogramGradient`. Previews reserve 2 lines (38 pt) |
| 1.2 | Needs-you gutter dot, ≥ 3:1, labelled | **PASS** | 10 x 10 pt at x 8. Light: #C93400 on #FFFFFF, **5.28:1**. Dark: #FF9F0A on #000000, **10.2:1**. AX label "Needs you", first in the row's label |
| 1.3 | Search field grows with the text | **PASS** | At AX5 the field is 64 pt tall inside a capsule of about 78 pt, and "Search" is no longer clipped (`ax5-light/01-home.png`). At Large it is 36 pt |
| 1.5 | Pin block 136 pt; preview while Chief waits | **PASS**, with defect F3 | AX: `home.chief` is 168 to 302 = **134 pt** (spec 136; within tolerance). The preview shows for a question that has not been seen, and it clears after the chat is opened (`light/08-home-after-back.png`). See F3 for its collision with the search field |
| 1.6 | Filters apply to Chief; "No Conversations" | **PASS**, with spec gap F6 | Unread hides the pin and shows "No Conversations", centered below search (`light/04`). Needs You keeps cmux and ghostty and hides the pin (`light/03`). See F6 |
| 1.7 | AX5 stacked rows | **PASS** | `ax5-*/01-home.png`. The title is on its own line ("cmux.com" in full, 244 pt wide). The date and chevron are on line 2, and the date does not wrap ("3:52 AM", 1 line, 58 pt). The preview is up to 3 lines. The avatar is about 64 pt (the cap), top-aligned. The "Chief" caption fits |
| 2 / 3 | One Chief drawing | **PASS** (phone) | `chief-avatars-pin-header-details.png`: white "C" in a circle on Home's pin (88 pt), in the chat header and on the details page (72 pt), in dark and light. The sparkles are gone. Pixel samples: pin (162,166,185) and details (164,170,187) are the same slate. In light, the header reads bluer, (157,179,217), because the blue bubble behind the glass header washes it (3.1 keeps the wash). Mac side: `chief.engine.get` has no `avatar` yet, so "C" is shown everywhere. That is correct for now (see F7) |
| 4, 5, 12, 13 | Markdown, lock, "+" menu, keyboard from a scrolled-up transcript | Out of scope (upstream) | Still raw backticks in the bubble (`ax5-light/05-chief.png`). Judged only through UPSTREAM-REQUESTS.md (below) |
| 6 | Details page: truthful, no dead controls | **FAIL** (F1, F2) | Without a Mac: status "Not connected to your Mac" agrees with "Connect to your Mac to choose Chief's model." No pickers, no Name field, no title in the bar, and only Done (`light/06-details.png`). The toggles are enabled because mock has a conversation id; the disabled state was not reachable. The connected state could not be produced with mock; the code was read instead. See F1 and F2 |
| 8 | Hidden sidebar out of the AX tree | **PASS** | Manaflow, Personal, Build Fleet, Invite to team and Add team are absent with the sidebar closed (0 matches in `01-…closed.json` and `12-…closed-again.json`, dark and light). They are present when it is open (`11-…open.json`), and then the Home rows are gone. The escape action exists (`SidebarContainer.accessibilityPerformEscape`); VoiceOver was not run |
| 9 | New Message fixes | N/A | Removed from Home by the user's decision |
| 10 | Pin state without opening the chat | **PASS** | See 1.5 |
| 11 | Filters include Chief | **PASS** | See 1.6 |
| 14 | Seed order (DEBUG) | **PASS** | The transcript reads in time order (`dark/05-chief.png`) |
| 15 | Keep the transcript behaviors | **PASS** | The package is unchanged. Only the transcript in this walk was spot-checked; long press, the send-time drawer and the keyboard dismiss were not re-recorded |
| — | Dark and light | **PASS** | Every step was captured in both (`dark/`, `light/`); no contrast problems were found |
| — | Largest text size | **PASS**, except F3 | `ax5-light/`, `ax5-dark/` 01 to 09. The details page wraps cleanly at AX5 (`ax5-dark/06-details.png`) |

## Fix list for round 2

| # | Level | Fix | Evidence |
| --- | --- | --- | --- |
| F1 | Major (item 6) | **"Default" still has no name for a Codex Chief.** `ChiefSettingsView.defaultModelLabel` names the default from acpmux's `default` entry only when that entry's name is not "Default". Otherwise it uses `engine.model`. On 10-13 the live Codex Chief had `engine.model` nil and a menu whose first item read just "Default". Whether that came from acpmux's entry named "Default" or from no entry at all, this code still prints a bare "Default". Get the resolved model from the Mac: add a `resolvedModel` field to the `chief.engine.get` reply (the Mac already resolves it for `HomeChiefSidebar`'s pop-up), and use it for "Default (GPT-6.1 Sol)". Add a unit test using the 10-13 report shape | Code: `ChiefSettingsView.swift` `defaultModelLabel` |
| F2 | Minor (item 6) | **Raw error text on the details page.** `engineError = String(describing: error)` prints a Swift error dump in red under the Model section. Show a sentence instead ("Chief on your Mac didn't answer. Try again."), and keep the raw text in the log | Code: `ChiefSettingsView.load()`, `binding(_:_:)`, `stop()` |
| F3 | Polish (1.5, 1.7) | **The pin's preview bubble touches the search field.** The bubble is offset -26 pt above the avatar, but the pin's top padding is now 14 pt. At Large there is a 3 pt gap (capsule ends at 158, bubble starts at 161). At AX5 the two touch (capsule about 117 to 195, bubble from 193), and both use `surfaceRaised`, so they read as one shape. Keep at least 6 pt between the bubble and the capsule at every size: reduce the bubble's offset to fit inside the padding, or add top padding only while a bubble shows | `ax5-pin-bubble-vs-search.png`, `ax5-light/01-home.png` |
| F4 | Minor (2, 3.2) | **The pin preview and its VoiceOver label show raw Markdown.** Rows pass their previews through `ConversationsHome.plain`, but the pin uses `session.preview` raw. The pin label reads "…to run \`cargo test -p cmux-mobile-link\`…". Use `plain` for the pin's bubble and its label too | AX label of `home.chief` in `dark/01-home-ax-sidebar-closed.json` |
| F5 | Minor (VoiceOver) | **VoiceOver loses the harness.** The avatar is `accessibilityHidden`, and only a workspace's second agent tab has "· Codex" in its title. A first-tab row reads "cmux, 3:49 AM, Refactor transport layer", with no Claude or Codex. Append the harness to the label: "cmux, Claude, 3:49 AM, …" | `dark/01-home-ax-sidebar-closed.json` |
| F6 | Spec gap (1.5 and 1.6) | **The pin's waiting state and the Needs You filter disagree.** The pin shows Chief waiting on you (a question not yet seen) while Needs You hides Chief, because `needsYou` requires `unreadCount > 0`. Both follow the letter of the spec, which defines "waiting" two ways. Amend the spec: Needs You includes Chief when `session.isWaitingOnYou`. Change `needsYou` to `!outbox.isEmpty || isWaitingOnYou || (idle and the last message is Chief's and unread)` | `light/01-home.png` (preview up) and `light/03-filter-needs-you.png` (no pin) |
| F7 | Note for the Mac request (2) | **The Mac's avatar can be a picture.** `HomeChiefFiles` stores either text or a picture's file name in `profile.json` `avatar`. When `chief.engine.get` carries `avatar`, it must send text only (or a separate `avatarKind`). Otherwise the phone draws a file name such as "avatar.png" inside the circle. Until pictures are served, send `avatar` only when it is text | `Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/HomeChiefFiles.swift:33,56` |

Not verified, and why:

- Connected details (pickers, recent turns, Stop, Name and Avatar pages):
  mock content cannot produce a control channel, and the rules forbid pairing
  with a Mac. The labels were checked in code: `turnLine` gives
  "Failed · 2 min 57 s · 3 tools · $0.04", and `statusName` maps error,
  ok and stopped to words. F1 is the one gap found.
- The disabled toggles without a conversation id: mock always has one.
- VoiceOver itself: only the AX tree was checked.

## UPSTREAM-REQUESTS.md: is it precise?

**Yes, enough to act on.** Each item names the file or type, gives a Swift
signature, gives the default that keeps Messages parity, and says what Chief
passes. Small gaps for the package owner:

- **U1:** precise. It also states that the header's height must not change,
  which is good.
- **U2:** gives two options and marks the preferred one. It does not say how
  `rendersIncomingMarkdown` combines with runs a host already supplies
  (`ConversationTextRun`). Say which wins.
- **U3:** correctly withdraws the Camera request (the package adds it when
  `isSourceTypeAvailable(.camera)`). "Default: on" changes the Messages lab
  host. That is intended as parity, but say so explicitly.
- **U4:** a measurement request with a clear decision rule. Fine.
- **U5:** fine. It is correctly marked low priority after the user's decision.
- **U6:** `trailingAccessibilityLabel` has no stated default. Say nil, which
  keeps the package's label.
- **U7:** precise. It notes the safe failure mode (no keyboard) of today's
  workaround.

## Files

`round1-review/`, every file under 5 MB:

- `dark/`, `light/`, `ax5-light/`, `ax5-dark/`: the 01 to 12 walk screenshots
  (402 px wide) and the AX trees with the sidebar closed, open and closed
  again.
- `dark-walk-402w.mp4`, `light-walk-402w.mp4`: the whole walk.
- `compose-402w.mp4`, `compose2-402w.mp4`: the compose timing runs (load 38
  and 22). `compose-run1-10fps-sheet.png` is a contact sheet of the first.
- `compose-ax.json`: the AX tree after compose, showing the focused composer.
- `chief-avatars-pin-header-details.png`: Chief's avatar on the pin, in the
  header and on the details page, light (top) and dark (bottom).
- `ax5-pin-bubble-vs-search.png`: F3 at 3x.
