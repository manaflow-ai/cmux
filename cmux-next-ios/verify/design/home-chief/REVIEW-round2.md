# Home and Chief, round 2: designer review

Fresh designer review, 2026-10-14, of `origin/feat-cnx-ios` `bf52179e87`
against [SPEC.md](SPEC.md), the [round 1 fix list](REVIEW-round1.md), and
the three new round 2 features. The files in `round2/` are the implementer's
claims. Every result below comes from my own build and captures, in
`round2-review/`.

**Verdict: NOT SIGNED OFF.** Round 1's F1, F2, F4, F5, F6 and F7 pass, and
the answer flow never says "Sent" before the Mac has stored the answer. Four
Major findings block sign-off:

- The question bar covers the transcript. At the top of the history, part of
  the first message can never be scrolled into view (R2-1).
- At AX5, the status of an answer is off screen in the question sheet (R2-2).
- The pairing banner tells the user to check a Mac notification. The
  documented Mac shows a dialog, not a notification (R2-3).
- The two-line pairing banner covers the first row of the list (R2-4).

## How this was checked

- **Build:** Debug (mock) and Production simulator builds of `bf52179e87`.
  Xcode at `/Applications/Xcode.app`, `-jobs 4`, `-derivedDataPath
  /tmp/cmux-mobile-home-review3-dd`. Both built cleanly.
- **Simulator:** one headless simulator, `cmux-mobile-home-review3` (iPhone 17 Pro,
  iOS 26.5, 402 x 874 pt). Simulator.app was never opened, and the simulator
  was deleted afterwards. Taps were HID touches through `axe`.
- **Content:** mock content (`CMUX_MOBILE_MOCK_AUTH=1`), so this checks **mock
  (layout only)**. There was no Mac and no pairing, and Chief sent nothing.
  The mock's "Face ID" is a 1.4 s pause, and nothing is signed. The pairing
  banner is forced with `-cmux-mobile-banner-demo`.
- **Walks:** I re-ran `round2/capture.sh` in dark, light (recorded), AX5
  light and AX5 dark. I also ran `flow.sh`, which records two answer flows.
  The first stays in the sheet (light). The second closes the sheet right
  after the tap, so the bar carries the states (dark). I added one
  top-of-history check and AX dumps of the banner.
- **Load:** the 1-minute load was 58 to 66 during the dark walk. The 05 and
  06 stills there are off by a state (06 already shows the sheet
  dismissing). The two flow recordings started at load 39.7 and 28.8, below
  40, and they are the timing evidence.
- **Units:** points. The screenshots in `round2-review/` are downscaled to
  874 px tall (402 px wide), so 1 px = 1 pt. Gaps are column scans of the
  full-resolution (3x) PNGs.
- **Production:** installs and launches to sign-in (`production-launch.png`).
  `strings` on the binary finds 0 matches for `cmux-mobile-banner-demo`,
  `CMUX_MOBILE_MOCK_AUTH` or the mock reply, and 3 matches for the new strings. I did
  not sign in, because that would need a Mac to pair with.

## The three new features

| Feature | Result | Evidence and measurement |
| --- | --- | --- |
| Answer states: "Waiting for Face ID…", then "Sending…", then "Sent", with "Sent" only after the Mac stores the answer | **PASS** (order and truth); see R2-2 and R2-5 | `flow-sheet-light-5fps-sheet.png`: after the Allow tap, "Waiting for Face ID…" shows for about 1.4 s, then "Sending…" for about 0.6 s. Then "Sent" with a check and "You answered · Allow" shows for 1 frame (about 0.2 s) before the sheet closes, and Chief's reply arrives. Code: `ChiefAnswerFlow.approved()` runs only from `ChiefApprovalNotifyingSigner`, after the signature exists. `stored()` runs only after `conversation-op` returns the changed message (`Core.answer`). A second tap does nothing (`begin()`). Cancelled Face ID and missing pairing each have their own sentence. With the sheet closed (`flow-bar-dark-5fps-sheet.png`), the bar shows a spinner with "Waiting for Face ID…", then "Sending…", then goes away. Real Face ID was not exercised: that needs a paired Mac |
| Two-line pairing banner | **FAIL** (R2-3, R2-4) | `*/09-pairing-banner.png`, `*/10-pairing-banner-reset.png`, `banner-*-ax.json`. The layout reads well: a spinner, a semibold line, then a secondary line, and it wraps at AX5, capped at AX2. But the second line points to something the Mac does not show, and the banner covers the list |
| Live `chief-profile-changed` avatar | **NOT VERIFIED; code risk** (R2-6) | `ChiefQuestionTests.profileEventRedrawsChief` covers the backend and the store. No Mac code emits the event: `git grep` on `origin/feat-cmux-next` `cmux-tui` and the diff of the open Mac PR #20531 have 0 matches. Mock content cannot produce it either |

### The question bar over the first visible bubble: not acceptable

Messages never floats a control over the bubbles. Its own pinned rows (the
business chat request, "Report Junk", the add-contact strip) sit under the
header and push the transcript down. Glass is fine. Hiding content is not:

- **At rest** (`question-bar-resting-ax.json`, `dark/03`, `light/03`): the bar
  is y 185 to 253 (68 pt). It covers 68 of the 100 pt of the Chief bubble
  `msg_local_3` (185 to 285). Only "your Feed." is readable.
- **At the top of the history** (`question-bar-top-of-history-ax.json`,
  `question-bar-resting-vs-top-of-history.png`): fully scrolled up, the first
  message `msg_local_1` starts at 232, under the bar's bottom edge at 254. Its
  "Chief" label, its time and its first line are covered for good. No scroll
  position shows them.
- **Through the glass** (`question-bar-light-ghosting-3x.png`): in light mode
  the covered bubble's text shows through behind the bar's secondary text, at
  a similar size. "One thing: Claude in cmux wants" competes with "Allow
  Claude in cmux to run…".
- **While busy** (`question-bar-busy-dark-crop.png`): the bar shrinks to 2
  lines, and its bottom edge cuts through a line of bubble text.
- **At AX5** (`ax5-light/03`): the bar covers the top half of the last Chief
  bubble.

## Round 1 fix list, re-checked

| # | Result | Evidence and measurement |
| --- | --- | --- |
| F1 Default model named | **PASS** (phone), **pending** on the Mac | `resolvedDefaultName` reads `offered.default_model`, then the default entry's `resolves_to`, then `engine.model` with `model_is_default`. These are the fields Mac PR #20531 sends (its diff, lines 61 to 220). Tests `resolvedDefaultDecodes` and `defaultModelLabelNamesTheModel` include the 10-13 shape, which gives plain "Default". #20531 is still **open** (base `feat-cnx-ios-machost`), so live users see plain "Default" until it lands. That is honest, so it is not a phone defect |
| F2 Errors as sentences | **PASS** (code) | `ChiefSettingsView.errorText` logs the raw error and shows one sentence per action. Try Again appears only when nothing loaded. Without a Mac, the details page shows "Not connected to your Mac" and no red text (`*/08-details.png`) |
| F3 Bubble at least 6 pt clear of search | **FAIL at AX5** (R2-7) | Column scan: at Large the capsule is 122 to 158 and the bubble 166 to 202, a **8 pt** gap (the claim was 13). At AX5 the capsule is 118 to 194 and the bubble starts at 198, a **4 pt** gap (the claim was 8; the spec is at least 6) |
| F4 Pin preview plain | **PASS** | The `home.chief` label is "Chief, Heads up: Claude in cmux is asking to run cargo test -p cmux-mobile-link. Want me to allow it?", with no backticks (`dark/01-home-ax.json`) |
| F5 Harness in row labels | **PASS** | "Needs you, cmux, Claude, 4:47 AM, Refactor transport layer"; "cmux.com, Codex, …" |
| F6 Needs You includes a waiting Chief | **PASS** | `*/02-needs-you-with-chief.png`: the pin and its bubble stay, with cmux and ghostty |
| F7 Avatar text only | **PASS** (code) | `avatarText` rejects paths, picture extensions, control characters and non-string values. Tests cover it |

## Spec items, re-checked

| # | Result | Evidence |
| --- | --- | --- |
| 1 Compose opens Chief (user decision) | **PASS** | No change since round 1. The compose control is still "New Message to Chief". Not re-timed |
| 1.1 No title; chevron-only back button | **PASS** | No "Conversations" text in any Home capture |
| 1.2 Rows, 1.3 search, 1.7 AX5 rows | **PASS** | `*/01-home.png`. Needs-you dots are #C93400 in light and #FF9F0A in dark. At AX5 the search field holds "Search" without clipping |
| 1.5 Pin | **PASS** except R2-7 | |
| 1.6 Filters | **PASS** | F6 |
| 2 and 3 One Chief drawing | **PASS** | A "C" on the pin, in the header, in the details page and in the question sheet (40 pt) |
| 4, 5, 12, 13 (upstream) | Out of scope | Raw backticks are still in the Chief bubble (`dark/03`) |
| 6 Details page truthful | **PASS** (mock) | |
| 8 Sidebar out of the AX tree | **PASS** | 0 sidebar labels in `*/01-home-ax.json` |
| 14 and 15 | **PASS** | The transcript is in time order. The package is untouched |
| Dark, light, AX5 | **FAIL** at AX5 (R2-1, R2-2, R2-4, R2-7) | `ax5-light-sheet.png` |

## Fix list for round 3

| # | Level | Fix | Evidence |
| --- | --- | --- | --- |
| R2-1 | Major | **The question bar must not cover the transcript.** Inset the conversation by the bar: set `conversation.additionalSafeAreaInsets.top` (or a package top-inset hook; file it as upstream U8 if the package ignores safe area) to the bar's height plus 8 pt. Animate the inset with the bar, and remove it when the bar goes away. Acceptance: at rest and at the top of the history, no bubble, sender label or time is under the bar, in light, dark and AX5 | `question-bar-resting-ax.json`, `question-bar-top-of-history-ax.json`, `question-bar-resting-vs-top-of-history.png`, `question-bar-light-ghosting-3x.png` |
| R2-2 | Major | **At AX5 the answer's status is off screen.** After Allow, "Waiting for Face ID…" is below the fold of the large-detent sheet (`ax5-light/05`, `ax5-dark/05`), because the header block (a 40 pt avatar, "Chief" and a 4-line subtitle) uses about 250 pt. In `ax5-light/04-question-sheet-ax.json` the question text is at y 454 to 703, Allow at 715 to 957, and Answer at 1059 to 1099 on an 874 pt screen. "Don't Allow" and the status row are off screen until the user scrolls. Move the status row into a bottom `safeAreaInset` (or put it above the card) so it shows at every size. Cap the subtitle at 2 lines, or drop it at accessibility sizes | `ax5-light/05-waiting-for-face-id.png` |
| R2-3 | Major (truth) | **"Check your Mac's notification" has no notification behind it.** `verify/phone-approvals.md` (lines 128 to 133 and 280 to 284, on this branch) says the Mac shows an app-scope cmux dialog. It also says a system notification "would fix it" and does not exist yet. Say what is true today: "Approve this iPhone on <Mac>" and then "cmux on your Mac is asking". Point at a notification only once the Mac posts one | `States.swift` `waitingForPairing` |
| R2-4 | Major | **The pairing banner covers the list.** At Large, its glass (text at 132 to 164, about 124 to 172 with padding) covers the "Needs You" header (116 to 148) and 14 pt of the "cmux" title (158 to 178). At AX5, the glass (about 124 to 272) hides the header and the whole first row title (195 to 258). Put the banner in `safeAreaInset(edge: .top)` so the list moves down, or inset the list by the banner's height | `banner-large-ax.json`, `banner-ax5-ax.json`, `*/09-pairing-banner.png` |
| R2-5 | Minor (truth) | **A lost reply reads as "Not sent".** Any transport error or timeout from `client.request` after the op went out falls to "Not sent: Chief on your Mac didn't take the answer. Try again." The Mac may have stored it. Then the retry gets `question_closed`, which reads "Chief no longer needs this answer." Only refusals the Mac returns (forbidden, invalid_answer, question_closed), a cancelled Face ID and a missing pairing can say "Not sent". A transport failure should say "Couldn't confirm with your Mac." and let the question feed settle the state | `ChiefAnswerFlow.text`, `Core.call` |
| R2-6 | Minor | **The avatar event has no sender, and a missing key resets the avatar.** No Mac code emits `chief-profile-changed`. When it lands, an event without an `avatar` key (for example a name-only change) runs `applyAvatar(nil)` and resets Chief to "C". Apply only when the key is present (`object.keys.contains("avatar")`), with a test. Verify end to end once the Mac emits the event | `ChiefDaemonBackend.Core.route` |
| R2-7 | Polish | **F3 at AX5:** the gap is 4 pt, under the 6 pt minimum. Make `bubbleClearance` scale (`@ScaledMetric`), or measure the bubble | Column scan above |
| R2-8 | Polish | **The question card's "Answer" button reads as dead.** For a single-choice question, tapping an option sends at once, and "Answer" stays disabled the whole time (`*/04-question-sheet.png`). Hide it for single choice, or make the option select and Answer send. The spec rules out controls that look dead | `dark/04-question-sheet.png` |

## Not verified, and why

- Real Face ID, signing, and the Mac storing the answer: no pairing is
  allowed. The truth of the flow was checked in code and in the mock's
  order.
- `chief-profile-changed` on a live Mac: no emitter exists (R2-6).
- The connected details page: mock content cannot produce it.
- VoiceOver itself: only AX trees were checked.

## Files (`round2-review/`, every file under 5 MB)

- `dark/`, `light/`, `ax5-light/`, `ax5-dark/`: steps 01 to 10 of
  `capture.sh` (402 px wide) and their AX trees.
- `light-walk-402w.mp4`: the recorded light walk.
- `flow-sheet-light-402w.mp4` and `flow-sheet-light-5fps-sheet.png`: the
  answer in the sheet (load 39.7). `flow-bar-dark-402w.mp4` and
  `flow-bar-dark-5fps-sheet.png`: the answer with the sheet closed (load
  28.8).
- `question-bar-*`: the R2-1 evidence (AX at rest and at the top of the
  history, the 3x crop in light, and the busy crop in dark).
- `banner-large-ax.json`, `banner-ax5-ax.json`: the R2-4 frames.
- `ax5-light-sheet.png`: Home, Chief, the sheet, waiting, and both banners at
  AX5.
- `production-launch.png`: the Production build at sign-in.
- `capture.sh` (a copy of `round2/capture.sh`), `flow.sh`: the scripts used.
