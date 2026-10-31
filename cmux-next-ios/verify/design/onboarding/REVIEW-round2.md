# Onboarding design review, round 2

Designer review of the round 2 implementation against `SPEC.md`, 2026-10-14.
Every spec item was re-checked. The implementer's `round2/` captures and
`REVIEW-round1-response.md` were treated as claims; the evidence below is from
my own build and captures.

**Verdict: no sign-off.** Round 2 fixes the ghost chevron and the 0% start
(spec 5 and 6). I confirmed this with an A/B build. One spec item is still
open: "Get cmux for Mac" (spec 12). It is blocked on a user decision, not on
code (see the fix list). The 0.3 s hold delays the start by a measurable
amount; I list a small trim as Polish. Everything else passes.

## What was looked at

- Build: Production for the simulator, built from `origin/feat-cnx-ios`
  `05600628`. `dev.cmux.mobile.prod`, `CFBundleName` = `cmux`,
  `CmuxMobileAppleSignIn` = `NO`, `CmuxMobilePush` = `NO`.
- A/B variants of that same build (experiment only, not committed):
  - **A**: `launchCrossfade = 0`. The scene-phase gate is kept, so A has no hold.
  - **B**: `launchCrossfade = 0` and no scene-phase gate. B behaves like round 1.
- Debug build of the same SHA with mock auth (`CMUX_MOBILE_MOCK_AUTH=1`) to force a
  real error render. The mock rejects any code except 424242, so typing
  111111 shows the code step's error.
- Simulator: one headless iPhone 17 Pro, iOS 27.0 (`cmux-mobile-ob-review2`), 402 x 874
  pt at 3x. Simulator.app was never opened. Taps went through `axe`. The
  simulator was deleted afterwards.
- Host load (1-minute `vm.loadavg`): every timed recording waited for load
  below 40. A/B runs: 6.1-9.9. First HEAD set: 33-39. Idle recording: 27.0.
- Timing: frames were decoded with their real presentation timestamps (the
  recorder writes variable-rate H.264). Measurements are region means per
  frame (`scripts/analyze.py`, `scripts/summary.py`). All runs are in
  `round2-review/launch-runs.txt`.
- Captures are in `round2-review/`.

## Launch → Welcome (spec 4, 5, 6): the 0.3 s hold

### Ghost chevron (spec 5): PASS

| Build | Runs | Runs with a ghost | Ghost decay |
| --- | --- | --- | --- |
| HEAD (hold 0.3 s) | 12 (5 A/B-set + 7 earlier, dark and light) | **0** | none |
| A (no hold) | 5 | 5 | 0.88 → 0.09 of the mark over 0.20-0.217 s |
| B (round 1 behavior) | 5 | 5 | 0.87 → 0.09 over 0.20-0.217 s |

The ghost metric is the launch mark's lower half (a 72 x 28 pt box below the
headline band). Values are the fraction of the mark's contrast left in each
frame after the handoff.

- `handoff-HEAD-dark-1-60fps.png`, `handoff-HEAD-light-1-60fps.png`: one
  chevron in every frame. It leaves the center on the first frame
  (outQuint), and the center is clear from #1 on.
- `handoff-A-dark-1-60fps.png`: the same build without the hold. The second
  chevron stays at the center and fades through #2-#15 (0.2 s). This confirms
  that the system's launch-screen crossfade causes the ghost, and that the
  hold removes it.
- During the hold, the app's frames match the launch screen. In the mark's
  82 x 95 pt region, the mean pixel difference between the settled launch
  screen and the last pre-handoff frame is ≤ 0.07 levels. One codec pixel
  reaches 51. Only the status bar and the home indicator change (system).

### Controls start at 35% (spec 6): PASS

- On the first frame after the handoff, the Google row is at **45-52%** of its
  final contrast in all 12 HEAD runs. In A and B it is at 0-1%.
- 95% is reached at **+0.125-0.132 s** (Claude: +0.12 s). In A and B it is
  reached at +0.235-0.257 s, because the system crossfade drags the ramp.
- The headline and the three rows change together. They do not stagger or
  rise (`intro-timeline-dark.png`, +0.00 and +0.10).

### Does the hold make the start slower or stall it?

All values are seconds from the start of the launch zoom (first changed
frame), mean of 5 runs each, from the same host and session (load 6-10):

| | HEAD (hold) | A (no hold) | B (round 1) |
| --- | --- | --- | --- |
| Launch screen settled → handoff (static mark) | 1.41 | 1.07 | 1.21 |
| Zoom → handoff | 1.65 | 1.29 | 1.44 |
| Handoff → Google 95% | 0.13 | 0.24 | 0.25 |
| **Zoom → buttons at 95% (time to interactive)** | **1.77** | **1.54** | **1.68** |

- **Slower: yes, a little.** The static mark runs about 0.2-0.35 s longer
  because of the hold. The faster ramp afterwards recovers about 0.11 s.
  The net cost to time to interactive is **+0.09 s compared with round 1 (B)
  and +0.24 s compared with A**. Run-to-run spread is ±0.15 s, so B vs HEAD
  is near the noise.
- **Stall: no.** After the handoff, the longest gap between changed frames in
  the first 0.6 s is ≤ 0.067 s in all 12 HEAD runs except one. The very
  first launch after install had a 0.208 s gap at +0.08 s. A and B runs show
  ≤ 0.067 s. That one stall is not caused by the hold; re-check it on a
  device.
- **Compared with Claude:** Claude's launch screen to interactive is about
  0.69 s on a device (0.57 s launch screen + 0.12 s). The simulator's
  pre-`main` time dominates ours (1.0-1.2 s of static mark even without the
  hold), so the absolute numbers cannot be compared. After the handoff, cmux
  now matches Claude (+0.13 s vs +0.12 s).
- **The hold is longer than it needs to be.** In all 10 no-hold runs, the
  crossfade ghost is below 10% by 0.217 s. A 0.22 s hold would remove the
  ghost and save about 0.08 s of static mark (Polish 2).

### Launch mark ≤ 0.35 s (spec 4): FAIL, carried over; simulator-bound

The static mark is 1.07-1.41 s here. The hold makes it 0.2-0.35 s longer by
design. As in round 1, most of this is spent before `main` in the simulator.
This needs an on-device measurement of zoom → buttons at 95%, with and
without the hold, before anyone can decide on it. The phone is not authorized
for this review.

## Result per spec item

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Apple hidden unless TestFlight | PASS | Info.plist `CmuxMobileAppleSignIn=NO`. Three rows: Google, GitHub, email (`welcome-dark-ax.json`) |
| 2 | AX5 welcome and email | PASS | `welcome-ax5-and-rest-5up.png`: lockup top y 70, art hidden, headline 2 lines (137 pt), rows wrap at 149 pt, legal text reachable by scrolling (scroll bar "2 pages"). `email-ax5-light.png`: title and subtitle wrap, field and CTA grow. One new Polish note: see Polish 1 |
| 3 | Skip notifications without push or once decided | PASS (source, unchanged) | `SetupFlow.asksForNotifications()` checks `push` and `.notDetermined` |
| 4 | Launch mark ≤ 0.35 s | **FAIL (simulator-bound, carried over)** | See above. 1.07-1.41 s static. The hold adds 0.2-0.35 s by design |
| 5 | No ghost chevron | PASS | 0 of 12 HEAD runs; 10 of 10 no-hold runs show it (`handoff-*-60fps.png`) |
| 6 | Controls 35% → 100% together in 0.22 s | PASS | First frame 45-52%; 95% at +0.13 s; no stagger or rise |
| 7 | One thread and one dot; nothing crosses the phone | PASS | `intro-timeline-dark.png`. Art motion runs +0.00 to +4.10 s, then rests (frame differencing in the art box) |
| 8 | Errors overlay; copy names the provider; contrast | PASS (welcome by source; color rendered) | Welcome `errorLine` uses `dangerText` and the overlay is unchanged from round 1. Rendered error (`code-error-2up.png`, mock wrong code): light text pixels **#D70015** on #FFFFFF = **5.38:1**; dark **#FF453A** on the sheet's #1C1C1E = **4.99:1**. Both meet 4.5:1. The production welcome error can't be triggered offline |
| 9 | Choose a space; "Create a team" 0.1 s later | PASS (source) | `showsCreate` is set inside `withAnimation(smooth.delay(0.1))` on `.loaded`. The row keeps its layout space (opacity only) and has `allowsHitTesting(showsCreate)`. The nested transition is gone |
| 10 | System sheet says "cmux" | PASS | `CFBundleName` = `cmux`. The GitHub OAuth app name is an account setting and was not checked |
| 11 | Legal contrast ≥ 4.5:1 | PASS (unchanged) | `legal` token: 6.36:1 dark, 5.63:1 light |
| 12 | Connect your Mac: art, wait loop, "Get cmux for Mac" | **FAIL (blocked on a user decision)** | Wait loop PASS (source): `IdleStyle.waiting` is 1.5 s every 2.4 s, thread 0-0.5, dot 0.5-1.3 at 35%, fade 1.2-1.5. **"Get cmux for Mac" is missing.** Checked: `https://cmux.com/download` returns **404**, and manaflow-ai/cmux#20414 (the Mac app's Settings → Mobile) is still **OPEN** |
| 13 | One idle event 4 s after rest | PASS | `welcome-dark-idle-402w.mp4`: rest at +4.10 s, idle at +8.20 to +9.98 s (+4.10 s after rest). Source: `idlePlayed` stops repeats (unchanged since round 1, which saw no repeat through 24 s) |
| 14 | Email sheet copy and growth; disabled CTA | PASS | `email-states-6up.png`. The disabled CTA is the accent capsule at 40%: dark pixel (119,119,120) = 0.4 x 255 + 0.6 x 28; light (153,153,153) = 0.6 x 255. Enabled: white (dark) and black (light). Title y 140, subtitle y 170, field 20 pt below |
| 15 | Verify spinner inside the code boxes | PASS (source, unchanged) | |
| 16 | Setup pages: title2 semibold, 24 pt above the footer | PASS (source, unchanged) | |
| 17 | Buttons 50 pt + 8 pt gap | PASS | Rows at y 616.3 / 674.3 / 732.3, each 50 tall, x 20, width 362 |

### Welcome layout at rest (`welcome-dark-ax.json`)

The layout is the same as round 1 and passes every row. Lockup top 70.0;
slot 159-181 and text at 188; art 260 x 136 at 239.7-375.7; headline 407.5
(31.8 below the art); buttons → legal 16; legal 798.3-832.0; legal width
259.3.

### Round 1 new issues

- **Light-mode error contrast:** PASS. Rendered at 5.38:1 (see item 8).
- **AX lockup proportions:** PASS. At AX5 the chevron is 33.5 x 48 pt (at the
  cap) next to the 67 pt wordmark (`welcome-ax5-dark-ax.json`). The lockup
  now reads as one unit. When the page scrolls, the chevron follows the slot
  (y 79.7 → -115.3 after a 195 pt scroll).

## Fix list

Required for sign-off:

1. **"Get cmux for Mac" (spec 12).** This is blocked on a user decision, not
   on code. The link has no working target (`cmux.com/download` returns 404),
   and the Mac setting the page tells the user to turn on is not shipped
   (#20414 is open). I recommend deferring this row until #20414 ships and a
   download URL exists, then adding it as specified. With that deferral
   accepted, this review becomes a sign-off: the rest of round 2 passes.
   - User decision: reply `defer Get cmux for Mac until the Mac setting ships`
     to sign off now with the row tracked as follow-up, or reply `ship it now
     with <URL>` to give a download URL the implementer should use today.

Not blocking (Polish):

2. **Trim the hold from 0.3 s to 0.22 s.** In 10 of 10 no-hold runs, the
   system crossfade ghost is below 10% by 0.217 s, so 0.3 s adds about 0.08 s
   of static mark. Before changing it, measure zoom → buttons at 95% on a
   device with 0.3 s, 0.22 s and 0 s. The device crossfade may differ from
   the simulator's.
3. **Provider icons don't scale at AX sizes.** At AX5 the 18 pt Google, GitHub
   and envelope glyphs sit next to labels about 40 pt tall
   (`welcome-ax5-and-rest-5up.png`). Use `@ScaledMetric(relativeTo: .headline)`
   for the icon size and slot, capped at about 32 pt.
4. **Comment accuracy.** `Colors.swift` says #D70015 is "5.7:1" on white; it is
   5.38:1.
5. **First-launch stall (unconfirmed).** The first launch after install showed
   a 0.208 s frozen frame at +0.08 s, mid-glide (1 of 13 runs). Check it on a
   device with the DEBUG pacing log.

## Not re-checked

- On-device launch time and the hold's effect on a device (spec 4, Polish 2).
  This review has no phone authorization.
- Reduce Motion: `simctl` can't toggle it. Source: during the hold, Reduce
  Motion draws the 72 pt mark and the controls at 0; afterwards it crossfades
  in 0.35 s. That matches the spec.
- The production welcome error line, which needs a failing provider sign-in.
  The `dangerText` token was rendered on the email code step instead.
- Anything after a real sign-in. Those items are source-reviewed above.
