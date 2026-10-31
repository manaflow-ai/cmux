# Response to the round 1 review

Implementer's round 2, 2026-10-14. These items answer `REVIEW-round1.md`.
Captures are in `round2/`. They come from a Production simulator build (one
headless iPhone 17 Pro, iOS 27.0, deleted afterwards). Each timed recording
waited for a 1-minute load average below 40: light 15.2, dark 12.0.

## Fix list

| # | Item | Status | Artifact |
| --- | --- | --- | --- |
| 1 | Ghost chevron and the 0% start (spec 5, 6) | **Done** | `round2/handoff-light-60fps.png`, `round2/handoff-dark-60fps.png`, numbers in `round2/handoff-*-60fps.txt` |
| 2 | "Get cmux for Mac" (spec 12) | **Not done: waiting on the user's decision** | none |
| 3 | Connect your Mac wait loop: 1.5 s at 35% | **Done (source)** | `WelcomeArt.IdleStyle.waiting` |
| 4 | "Create a team" 0.1 s after the rows | **Done (source)** | `TeamStep.showsCreate` |
| 5 | Disabled email CTA at 40% | **Done** | `round2/02-email-empty-dark.png`, `round2/14a-email-empty-light.png` |

### 1. Ghost chevron and the 35% start

Waiting for the scene to become active was not enough. In a 60 fps capture
with only that gate, the ghost was still there: the scene is already active
while iOS crossfades its launch screen into the app's first frames.

Now the intro clock starts at `-launchCrossfade` (0.3 s) once the lockup is
measured and the scene is active. While the clock is below 0, Welcome draws
exactly the launch screen and nothing else: the 72 pt mark at the same center,
with controls, wordmark and art at 0. The system crossfade therefore blends
two identical images. The intro starts after that, with the controls at 35%.

The hold runs on the intro's own frame clock, which already advances with
rendered frames, so it is not a sleep. See `WelcomeView.startIntroIfReady()`
and `WelcomeIntroClock.launchCrossfade`.

60 fps result, measured in seconds since the first welcome frame:

- One chevron in every frame. The center region goes straight from the launch
  mark (88.4 light, 85.5 dark) to the headline's ink (13 and 8). There is no
  fading second mark.
- On the first frame, the Google row is already at 63% of its final value in
  light (151.5 of 239) and 50% in dark (118.5 of 236). It never starts from 0.
  The first frame the recorder kept is about one frame past t = 0, where the
  easeOut from 35% has already risen.

### 2. "Get cmux for Mac"

This is left out on purpose and is waiting on the user's decision. The spec's
`https://cmux.com/download` returns 404. The Mac app with Settings → Mobile →
"Allow iPhone Connections" is still in an open PR (manaflow-ai/cmux#20414), so
a download link today would install a Mac app without the setting this page
asks for.

### 3. Connect your Mac wait loop

`WelcomeArt` now takes an `idleStyle` parameter. `.waiting` lasts 1.5 s and
repeats every 2.4 s:

- thread 0-0.5 s
- dot 0.5-1.3 s, drawn at 35%
- fade 1.2-1.5 s

The thread is drawn at 35%, as in the welcome. The welcome keeps `.welcome`,
which is 2.1 s with the dot at full strength.

### 4. "Create a team"

The row now has its own opacity, driven by `showsCreate`. That state is set
inside `withAnimation(smooth.delay(0.1))` when the phase becomes `.loaded`,
and the row takes no hits until then. The nested transition was removed.

### 5. Disabled email CTA

`CmuxMobileCapsuleStyle` now draws a disabled primary as the same `accent` capsule
at 40%. This applies to every `PrimaryCapsule` (email Continue, Create team).

## New issues

| # | Item | Status | Artifact |
| --- | --- | --- | --- |
| 1 | Light-mode error contrast | **Done (source)** | New `dangerText` token: dark #FF453A (6.16:1 on black), light #D70015 (5.38:1 on white). It is used by the welcome error line, both email steps and the Create team error. Errors need a failing sign-in, so they are not captured |
| 2 | AX lockup proportions | **Done** | `round2/16-welcome-ax5-light.png`, `round2/17-welcome-ax5-dark.png`: the chevron is `@ScaledMetric(relativeTo: .title2)` from 22 pt, capped at 48 pt. The launch glide lands on the measured slot size |

## Not changed

- **Launch mark at 0.85 s (spec 4).** Per the review, this is spent before
  `main`. The app's first log line to "intro started" is about 0.1 s, plus the
  0.3 s launch-screen hold above. Measure it on a device before changing any
  code.
- The GitHub OAuth app name ("cmux-agent") is an account setting for the user.

## Round 2 captures

Recorded in `round2/` at the same capture set as round 1:

- Welcome: dark and light (`01`, `13`).
- Email sheet: empty, invalid and valid in dark (`02`-`04`); empty and valid
  in light (`14a`, `14`).
- Largest text size: welcome in light and dark, scrolled, and the email sheet
  (`16`, `17`, `17b`, `18`).
- The intro recordings (`welcome-{dark,light}.mp4`) and the 60 fps handoff
  tiles.
