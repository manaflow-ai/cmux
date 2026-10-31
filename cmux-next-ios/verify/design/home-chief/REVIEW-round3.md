# Home and Chief, round 3: designer review

Fresh designer review, 2026-10-14, of `origin/feat-cnx-ios` `f0ec209c65`
against [SPEC.md](SPEC.md), [REVIEW-round1.md](REVIEW-round1.md) and
[REVIEW-round2.md](REVIEW-round2.md). The files in `round3/` are the
implementer's claims. Every result below comes from my own build and
captures, in `round3-review/`.

**Verdict: SIGN-OFF.** All eight round 2 findings pass, and so does every
spec item in scope. Nothing covers the transcript, and the answer flow is
truthful. Four new findings are Polish and do not block. One of them, R3-1,
should ship with the question bar (see the recommendation below).

## How this was checked

- **Build:** Debug (mock) and Production simulator builds of `f0ec209c65`,
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `-jobs 4`
  and `-derivedDataPath /tmp/cmux-mobile-home-review4-dd`. Both built cleanly.
- **Simulator:** one headless simulator, `cmux-mobile-home-review4` (iPhone 17 Pro,
  iOS 26.5, 402 x 874 pt). Simulator.app was never opened, and the simulator
  was deleted afterwards. Taps were HID touches through `axe`.
- **Content:** mock content (`CMUX_MOBILE_MOCK_AUTH=1`), so this is **mock (layout
  only)**. There was no Mac, no pairing, no E2E rig, and Chief sent nothing.
  The mock's "Face ID" is a pause, and nothing is signed. The pairing banner
  is forced with `-cmux-mobile-banner-demo`.
- **Walks:** `round3/capture.sh`, unchanged, in dark, light, **AX5 dark**
  (the implementer did not capture this one) and AX5 light. Then
  `flow.sh` recorded the answer flow twice: dark at Large, and light at AX5.
  I also scrolled to the top of the history at AX5 dark (the script's 10
  swipes do not reach it at AX5) and checked compose.
- **Load:** the 1-minute load was 90 during the dark walk, so its stills are
  layout evidence only. Both recordings started at a 1-minute load of 22.6
  and 20.5, below 40. They are the timing evidence (± 0.1 s).
- **Units:** points. Screenshots in `round3-review/` are 402 px wide, so
  1 px = 1 pt. Gaps come from column scans of the full-resolution (3x) PNGs
  (`scan.py`), and frames from `axe describe-ui` (`frames.py`).
- **Production:** installs as `dev.cmux.mobile.prod` and launches to sign-in
  (`production-launch.png`). `strings` on the binary finds 0 matches for
  `cmux-mobile-banner-demo` and `CMUX_MOBILE_MOCK_AUTH`, and finds the new strings ("Waiting
  for Face ID", "Couldn't confirm"). I did not sign in, because that would
  need a Mac.

## Round 2 fix list, re-checked

| # | Result | Evidence and measurement |
| --- | --- | --- |
| R2-1 Bar must not cover the transcript | **PASS** | Large, top of history (`dark/03b-chief-top-of-history-ax.json`): the bar is at y 66 to 134, the header at 138 to 226, and the first content (the service line) at 247. The first bubble starts at 309. AX5, top of history (`ax5-dark-top-of-history-ax.json`, after 30 swipes): the bar is at 66 to 209, the header at 213 to 305, and the service line at 322. At rest, everything under the bar is also above the header, in the scrolled-out area that the header already covers in Messages. The inset animates with a 0.35 s spring and honors Reduce Motion. `bar-top-of-history-large-ax5-dark.png` |
| R2-2 AX5 answer status off screen | **PASS** | The status row and Send Answer are pinned to the sheet's bottom. At AX5 dark, "Waiting for Face ID…" shows at y about 750 (`ax5-dark/06-waiting-for-face-id.png`, `r2-2-ax5-dark-sheet-04-06.png`). The AX5 light recording shows "Waiting for Face ID…" and then "Sending…" in view the whole time (`flow-ax5-light-402w.mp4`). The subtitle is gone at accessibility sizes. See R3-4 for "Don't Allow" |
| R2-3 Pairing banner names a notification | **PASS** | "Approve this iPhone on Mac Studio / Look for cmux on your Mac", and the reset form "…again… Its keys were reset. Look for cmux on your Mac". This is true for a Mac with the dialog and for one with #20491's notification (`verify/phone-approvals.md`) |
| R2-4 Banner covers the list | **PASS** | Large light: the banner's glass ends at about y 172, and the list (the "Needs You" heading) starts at 180. AX5 dark: the glass ends at 271, and the list starts at 280 (`*/10-pairing-banner-ax.json`, column scan) |
| R2-5 A lost reply reads "Not sent" | **PASS** (code, tests) | `ChiefAnswerFlow.failed` gives "Not sent" only before signing, or for a refusal (`ok:false` from the Mac, code -32000). Any other error after the answer went out becomes `.unconfirmed`: "Couldn't confirm. Chief may have it.", with Check, which refetches. When the question feed shows the question answered, the state turns to Sent. Test: `lostReplyIsUnconfirmedUntilChecked`, `recheckReadsTheMacsState`. Not exercised live |
| R2-6 Avatar event without a key resets the avatar | **PASS** (code, test); end to end still unverified | `object.keys.contains("avatar")` guards it, and `profileEventRedrawsChief` covers the no-key case. The Mac still has no emitter |
| R2-7 Pin bubble clearance at AX5 | **PASS** | Column scan at x 150: at Large, the capsule is at 122 to 158 and the bubble at 166, an **8 pt** gap. At AX5 (dark and light), the capsule is at 118 to 194 and the bubble at 206, a **12 pt** gap. The minimum is 6 pt (`r2-7-pin-bubble-vs-search.png`) |
| R2-8 "Answer" looks dead | **PASS** | Options only select. Send Answer is dimmed until a choice is made, then turns blue (`dark/04` → `dark/05`, `flow-dark-select-send-5fps-sheet.png`). This is a normal form, not a dead control |

## Round 1 and spec items, re-checked

| # | Result | Evidence |
| --- | --- | --- |
| F1 to F7 | **PASS** (no regressions) | F4: the pin's label has no backticks (`dark/01-home-ax.json`). F5: "Needs you, cmux, Claude, …". F6: Needs You keeps the Chief pin (`*/02`). F2: the details page shows "Not connected to your Mac" with no red text (`*/09`) |
| 1 Compose opens Chief, keyboard up | **PASS** | `home.compose` ("New Message to Chief") pushes Chief, and the composer has focus with the keyboard up (`compose-opens-chief.png`; this new simulator shows the keyboard's slide-to-type tip) |
| 1.1 to 1.7 Home | **PASS** | No title. Rows and search read correctly in dark, light and AX5 (`*/01-home.png`) |
| 2 and 3 One Chief drawing | **PASS** | A "C" everywhere: the pin, the header, the sheet and the details page |
| 6 Details page truthful | **PASS** (mock) | `*/09-details.png`, including AX5 dark |
| 8 Sidebar out of the AX tree | **PASS** | 0 matches for Manaflow, Build Fleet, Invite to team or Add team in `dark/01-home-ax.json` and `dark/03-chief-question-bar-ax.json` |
| 4, 5 (U1, U2), U3 to U8 | Upstream, out of scope | Raw backticks and the lock on the service line are still there |
| Dark, light, AX5 dark, AX5 light | **PASS**, with the Polish items below | All four sets are in `round3-review/` |

## New findings

| # | Level | Finding | Evidence |
| --- | --- | --- | --- |
| R3-1 | Polish (fix it with the bar) | **Transcript text shows above and around the bar.** The bar is an opaque card at y 70, but the band above it (the status bar, y 0 to 66) has no backing. Scrolled-out bubble text sits behind the clock and between the clock and the card ("Morning. Overnight…" at Large, a 34 pt "CEEDED." at AX5). The card therefore reads as a card floating over the conversation. Fix in mobile: put one material or opaque band behind the status bar and the bar, from y 0 to the bar's bottom + 4 pt, in the conversation's background color, so the bar reads as part of the top bar. The package header below keeps its own wash | `bar-position-at-rest-5up.png` |
| R3-2 | Polish | **The bar's dismissal overlaps the header.** After the answer is stored, the inset collapses at once while the bar is still on screen. For about 0.2 to 0.3 s (2 to 3 frames at 10 fps), "Chief is asking · Sending…" is drawn under the back button and the avatar, and one frame drops the header's buttons. Fade the bar out (or slide it up) first, then animate the inset to 0 in the same spring | `bar-collapse-glitch-dark-10fps.png` (frames 21 to 25 of `flow-dark-402w.mp4` from 5.5 s), and also the AX5 light recording |
| R3-3 | Polish | **"Sent" is never seen.** The sheet goes from "Sending…" straight to dismissing. No frame at 5 fps (Large) or 4 fps (AX5) shows "Sent". Round 2 showed it for one frame. Chief's "Allowed. …" reply arrives a moment later, so the outcome is not lost, but the sheet's own confirmation is not shown. Hold "Sent" with its check for about 0.6 s before dismissing, or drop the state from the sheet | `flow-dark-sending-to-close-5fps-sheet.png` |
| R3-4 | Polish | **At AX5, "Don't Allow" is below the fold.** The pinned footer fixed the status (R2-2), but the sheet shows only the Allow row, cut mid-word ("workspace"). The second choice needs a scroll, and nothing hints at it. At accessibility sizes, use a smaller question heading (`.title3`, not the large title), or let the option rows sit above the fold | `ax5-dark/04-question-sheet.png`, `flow-ax5-light-402w.mp4` |

Also at AX5: the bar (143 pt) and the header (92 pt) take 305 pt before the
first message. With the keyboard up, the transcript has about a third of the
screen. This is the same with U8. Consider capping the bar's subtitle at
one line at accessibility sizes.

## The bar above the header: recommendation

**Recommendation: `keep the bar above the header` and ship it with R3-1.**
Do not wait for U8.

- **Messages-like?** Not quite. Messages pins its rows *under* the name, so
  the eye reads "who" and then "what they want". Here "Chief is asking"
  comes first and sits where an iOS notification banner drops down, so at
  first glance it can read as a system banner. The avatar and name pill
  sit right under it, which ties it back to Chief.
- **Intentional?** At Large, in dark and light, it looks deliberate: a
  full-width card that aligns with the header's 16 pt margins and has a
  clear "Answer" action. What makes it look accidental is R3-1: bubble text
  shows above the card and collides with the clock. That is most visible at
  AX5. With a backing band, the bar and status bar read as one top bar.
- **Function:** this is the round 2 blocker fixed. Nothing is ever under the
  bar, at rest or at the top of the history, at Large or AX5. Its height
  costs the same as it would under U8.
- **Waiting for U8** would leave either the covering bar (round 2's blocker)
  or no bar at all, which hides an open question that only the transcript
  mentions. Both are worse than this layout.
- When U8 lands, move the bar under the name pill with the same inset
  rules, and remove the R3-1 band.

## Not verified, and why

- Real Face ID, signing, the Mac storing the answer, and the
  "Couldn't confirm" and Check path: no pairing is allowed. These were
  checked in code and tests.
- `chief-profile-changed` from a real Mac: no Mac emits it yet.
- The connected details page: mock content cannot produce it.
- VoiceOver itself: only AX trees were checked.
- The dark walk's stills were taken at load 90. The recordings (load < 40)
  are the timing evidence.

## Files (`round3-review/`, each under 5 MB)

- `dark/`, `light/`, `ax5-dark/`, `ax5-light/`: steps 01 to 11 of
  `capture.sh` (402 px wide) and their AX trees.
- `flow-dark-402w.mp4` (Large, dark) and `flow-ax5-light-402w.mp4` (AX5,
  light): the answer flow. Contact sheets:
  `flow-dark-select-send-5fps-sheet.png` and
  `flow-dark-sending-to-close-5fps-sheet.png`.
- `bar-position-at-rest-5up.png`: the top 320 pt at rest (dark, light, AX5
  dark, AX5 light, and the keyboard up from compose).
- `bar-top-of-history-large-ax5-dark.png`, `ax5-dark-top-of-history.png`,
  `ax5-dark-top-of-history-ax.json`: R2-1.
- `bar-collapse-glitch-dark-10fps.png`: R3-2.
- `r2-7-pin-bubble-vs-search.png`: R2-7 (Large dark, AX5 dark, AX5 light).
- `r2-2-ax5-dark-sheet-04-06.png`: R2-2 at AX5 dark.
- `compose-opens-chief.png`, `compose-ax.json`: spec 1.
- `production-launch.png`: the Production build at sign-in.
- `capture.sh` (a copy of `round3/capture.sh`), `flow.sh`, `scan.py`,
  `frames.py`: the scripts used.
