# Onboarding design review, round 1

Designer review of the round 1 implementation against `SPEC.md`, 2026-10-13.

**Verdict: no sign-off.** The launch handoff still shows a ghost chevron and
the controls still fade in from 0. Both are Major items (spec 5 and 6), and
both appear in the implementer's own captures. The rest of the signed-out
flow matches the spec closely. Four smaller deviations and two new issues are
listed below.

## What was looked at

- Build: Production for the simulator, built here from `origin/feat-cnx-ios`
  `a6fd7703` (this includes `a8244120`, "cut Welcome in on the launch handoff").
  `dev.cmux.mobile.prod`, Info.plist `CFBundleName` = `cmux`,
  `CmuxMobileAppleSignIn` = `NO`, `CmuxMobilePush` = `NO`.
- Simulator: one headless iPhone 17 Pro, iOS 27.0 (`cmux-mobile-ob-review`), 402 x 874
  pt at 3x. Simulator.app was never opened. Taps went through `axe`. Element
  frames come from `axe describe-ui` (points). The simulator was deleted afterwards.
- Host load (1-minute `vm.loadavg`) before each timed recording: dark intro
  38.5, light intro 10.3, idle event 6.1. Every recording waited for load
  below 40. In the dark run the recorder still dropped frames during the
  intro, so its durations are ± 0.1 s; the light run's frames were dense.
- The round 1 captures in `round1/` were also checked. Their burst tile samples
  every 0.4 s, so it skips the handoff. `round1/experiment-no-launchmarkview-8fps.png`
  shows the same ghost (bottom row, second frame).
- Captures are in `round1-review/`. `handoff-*-60fps.png` frames are labeled
  with seconds since the handoff, which is the first frame where the welcome
  appears.
- **Source-reviewed** (these need a real account): errors, the code step,
  Choose a space, Create a team, Connect your Mac, notifications, and the
  setup pages.

## Result per spec item

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Apple hidden unless TestFlight | PASS | Info.plist `CmuxMobileAppleSignIn=NO`. Three rows: Google, GitHub, email (`welcome-dark-ax.json`). The TestFlight config sets `YES`, and `CmuxMobileApp-TestFlight.entitlements` has `com.apple.developer.applesignin` |
| 2 | AX5 welcome and email | PASS | `welcome-ax5-dark.png`: lockup top y 70 (below the safe area), art hidden, headline wraps (2 lines, 137 pt), rows wrap to 2 lines at 149 pt tall. `welcome-ax5-dark-scrolled.png`: legal text is reachable by scrolling. `email-ax5-dark.png`: title, subtitle and field wrap or grow (field text 65 pt in a 93 pt field), and the CTA grows |
| 3 | Skip notifications without push or once decided | PASS (source) | `SetupFlow.asksForNotifications()` checks `push` and `.notDetermined`. `planSetup` waits for that answer. `registerForRemoteNotifications` is gated on `push` |
| 4 | Launch mark ≤ 0.35 s | **FAIL (measured), cause out of the app's hands in the simulator** | The static mark shows from +0.60 s to +1.445 s after the recording starts: **0.85 s** (dark and light runs). Logs over 3 launches: `simctl launch` to the first app log is 1.07-1.21 s, and the first app log to `intro started` is 0.10-0.13 s. So auth no longer holds the mark. The time is spent before `main` (dyld and the app binary). Re-measure on a device before changing anything |
| 5 | No ghost chevron (one chevron in every frame) | **FAIL** | `handoff-light-60fps.png` #47-#70 and `handoff-dark-60fps.png` #40-#55: a 72 pt chevron stays at the launch position and fades out over **≥ 0.23 s**, behind "Your Macs, in your pocket.", while the real chevron glides up. See "Fix list" |
| 6 | Controls 35% → 100% together in 0.22 s, no stagger or rise | **FAIL (start value)** | Light run, mean of the Google button region: 252 (white) at +0.003 s, then 249, 238, 221, 201, 175 … 35 at +0.28 s. A 35% start would read about 165 on the first frame. Dark run: 5.5 → 220 over +0.015…+0.30 s. The rows arrive together (no stagger, no rise), but from about 0%, not 35%. This has the same cause as 5 |
| 7 | One thread and one dot; nothing crosses the phone | PASS | `intro-art-timeline-dark.png`: Mac 0.1-1.3, phone 0.7-1.5, prompt 1.3-1.6, thread 1.6-2.2, dot 2.2-3.2, bloom into the chevron 3.2-3.7, retract 3.6-4.1, rest about +4.3 s. Each is within +0.1 s of the spec. The arc's control point is 40 pt above the higher end (source). Note: an arc from inside the Mac screen to the phone's center has to cross each outline once. "Never crosses" in the spec can only mean "never runs along an outline", and the build meets that |
| 8 | Errors overlay with no layout shift; copy names the provider | PASS (source) | `errorLine` is overlaid with its bottom 12 pt above the first row and grows upward. Copy: "Couldn't sign in with {Google/GitHub/Apple}. Try again.", and connection errors keep their own copy. In: opacity plus 6 pt offset with `snap`. Cleared by `signIn` on the next tap (and by the email row). Cancel stays silent: `google-cancel-dark.png` has no error element. The band from headline bottom (441) to the first row (616) is 175 pt, more than the 60 pt the spec requires |
| 9 | Choose a space: Personal first, title while loading, skeletons | PASS with one defect (source) | The title and subtitle are drawn on every phase. Personal is always row 1 (36 pt `person.fill` on `fillSelected`, radius 10, "Just you" plus dots). There are 2 skeleton rows with `delay: .zero`. Failure shows "Couldn't load your teams." with Retry inline, and Personal still works. **Defect:** "Create a team" has its own delayed transition, but it sits inside the loaded `VStack`, which is inserted with `.transition(.opacity)`. A child's transition does not run when its parent is inserted, so the row arrives with the team rows instead of 0.1 s after them |
| 10 | System sheet says "cmux" | PASS | `google-alert-dark.png`: “cmux” Wants to Use “accounts.google.com” to Sign In. Renaming the GitHub OAuth app is a service setting and was not checked here |
| 11 | Legal contrast ≥ 4.5:1 | PASS | Text `legal` token. Dark (141,141,147) on black = **6.36:1**. Light (103,103,108) on white = **5.63:1** (screenshot pixels match the token). It is `footnote`; links are `label` and underlined |
| 12 | Connect your Mac: welcome art, waiting loop, "Get cmux for Mac" | **FAIL (partial)** (source) | The art is `WelcomeArt` at 200 pt, rests at `rideStart`, and plays the ride and bloom when a Mac is found, with a success haptic. "Not now" crossfades to "Continue" with `snappy`. **Missing:** "Don't have cmux on your Mac?" and the "Get cmux for Mac" share action (no `cmux.com/download` anywhere). **Deviation:** the wait loop plays the full 2.1 s welcome idle event every 2.4 s (moving 88% of the time), and its dot is drawn at 100%. The spec asks for a 1.5 s event at 35% |
| 13 | One idle event 4 s after rest, no repeat | PASS | `welcome-idle-dark-402w.mp4` / `idle-event-dark.png`: rest at 5.70 s, idle from 9.72 s (+4.02 s), done at 11.85 s (2.1 s). The thread draws at 35%, the dot travels, the glow beats, and the thread fades. No frames change after that through the end of the recording (24 s) |
| 14 | Email sheet copy and growth | PASS with one deviation | Title "What's your email?" at y 140; subtitle 6 pt below (y 170); field container top 20 pt below (y 208); placeholder `name@example.com`; CTA "Continue" 52 pt, bottom 12 pt above the keyboard. AX5 grows (item 2). **Deviation:** the disabled CTA is `fillSelected` with `label3` text (`email-empty-dark.png`, `email-invalid-dark.png`), not the enabled capsule at 40% opacity |
| 15 | Verify spinner inside the code boxes | PASS (source) | The boxes dim to 0.4, with `ProgressView` overlaid on them. They grow with `@ScaledMetric` and form 2 rows of 3 at AX sizes |
| 16 | Setup pages: title2 semibold, 24 pt above the footer | PASS (source) | `SetupPage`: symbol 40 pt, `sidebarTitle` (= `title2.semibold`) centered, actions 10 apart, `.padding(.bottom, 24)` above the footer inset. The `signedOut()` comment is fixed |
| 17 | Buttons 50 pt + 8 pt gap | PASS | Rows at y 616.3 / 674.3 / 732.3, each 50 tall: gap 8. Side margin 20 (x 20, width 362) |

### Welcome layout, measured at rest (`welcome-dark-ax.json`, points)

| Element | Spec | Measured | Result |
| --- | --- | --- | --- |
| Lockup top | safe area + 8 = 70 | 70.0 | PASS |
| Chevron and gap | 22 pt, 7 pt gap | 22 tall; slot ends at 181, text starts at 188 | PASS |
| Art | 260 wide, no 1.12 scale | 260 x 136 (box trimmed to the drawing, scale 1.0) | PASS (the box height differs from the spec's 208 only because empty space was removed) |
| Art → headline | 32 | 375.7 → 407.5 = 31.8 | PASS |
| Hero optical center | centered between lockup and buttons, raised 16 | free-space center 356.3, hero center 340.5 → raised 15.8 | PASS |
| Buttons → legal | 16 | 782.3 → 798.3 = 16 | PASS |
| Legal bottom | 8 above the safe area (840) | 832.0 | PASS |
| Legal width | ≤ 340 | 259.3 | PASS |
| Icon slot to title | 22 slot, 10 gap | Google: slot 99.7-121.7, title at 131.7 | PASS |
| Light secondary rows | `bg` with a 1 pt `separator` stroke | yes (`welcome-light.png`) | PASS |

### Other checks

- **Dark and light:** both captured (`welcome-dark.png`, `welcome-light.png`,
  and the intro videos). PASS.
- **Vendor names:** no internal vendor names appear in onboarding copy. "Stack"
  appears only in a log line. Google, GitHub and Apple are sign-in options
  shown to the user, not internal vendors. PASS.
- **Dead controls:** none. Apple is gone in Production. Resend shows its
  countdown. Retry is inline. PASS.
- **Email sheet dismissal:** with the keyboard up, the welcome behind the sheet
  re-lays out (headline y 128, art hidden). `email-close-dark.png` shows it is
  back in its rest layout before it is uncovered. No visible jump. PASS.

## Fix list (required for sign-off)

1. **Ghost chevron and the 0% start (items 5 and 6).** The app's code is
   already a cut: `LaunchMarkView` uses `.transition(.identity)`, and Welcome's
   insertion is `.identity`. The fade that remains matches iOS's own
   launch-screen-to-first-frame crossfade. Evidence: the app's first frame is
   about 0.1 s after its process starts (logs), and Welcome's first rendered
   frame is already mid-intro. The system then crossfades the
   `UILaunchScreen` snapshot (72 pt `LaunchMark`) into it, about 0.25 s.
   During that crossfade the snapshot's chevron is the ghost, and the
   controls fade up from 0 instead of 35%. Fix: make the app's first frames
   identical to the launch screen until the system's transition has finished.
   Then start the intro clock. Two ways to do this:
   - Render `LaunchMarkView` (or Welcome at `t = 0` with controls at 0 and
     only the 72 pt mark drawn) until the scene reports `.active`. Start
     `WelcomeIntroClock` from that change, not from the first
     `onGeometryChange` of the lockup.
   - Or hold `t` at 0 with nothing but the mark visible for the crossfade's
     length, then jump the controls to 35%. Prefer the scene-phase signal
     over a fixed delay; the repository rules forbid sleeps for
     synchronization.

   Acceptance is unchanged: in a 60 fps capture (load < 40), exactly one
   chevron is visible in every frame after the launch screen. The first frame
   that shows the headline shows it and the rows at about 35%. If the
   cause turns out to be something else, record a 60 fps capture with
   the change, as in `handoff-light-60fps.png`.
2. **"Get cmux for Mac" (item 12).** Under the Connect your Mac steps, add
   "Don't have cmux on your Mac?" (`rowSubtitle`, `label2`) and a
   "Get cmux for Mac" text button. It opens a share sheet (`ShareLink`) with
   `https://cmux.com/download`.
3. **Connect your Mac wait loop (item 12).** Play a 1.5 s event at 35% every
   2.4 s: thread 0-0.5 s, dot 0.5-1.3 s, fade 1.2-1.5 s. Draw the dot at 35%
   too. Don't reuse the 2.1 s welcome idle event at full dot opacity. Add a
   `WelcomeArt` parameter such as `idleOpacity` / `idleTiming` rather than
   forking the drawing.
4. **"Create a team" delay (item 9).** Delay the row's appearance itself.
   For example, keep a `showsCreate` state set inside
   `withAnimation(smooth.delay(0.1))` when the phase becomes `.loaded`, or
   apply `.opacity(…)` with the delayed animation to the row. A nested
   `.transition` does not run when its parent is inserted.
5. **Disabled email CTA (item 14).** Disabled should be the enabled `accent`
   capsule at 40% opacity, not `fillSelected` / `label3`. If the gray style is
   kept on purpose for every `PrimaryCapsule`, say so and I'll update the
   spec instead.

## New issues (not in the spec)

1. **Light-mode error text contrast (Major).** The welcome error line is
   `footnote` `danger`. In light mode, #FF3B30 on white is **3.55:1**, below
   4.5:1. Use a darker red for small text in light mode. iOS's high-contrast
   system red #D70015 is above 5:1. Add a `dangerText` token (dark #FF453A =
   6.16:1 on black, light #D70015) and use it for the welcome, email and
   setup error lines.
2. **AX lockup proportions (Polish).** At AX5 the wordmark grows to 67 pt tall
   but the chevron stays 22 pt (`welcome-ax5-dark.png`), so the lockup looks
   broken. Scale the chevron with the wordmark, e.g.
   `@ScaledMetric(relativeTo: .title2)`, capped where it fits. The launch
   glide target is the measured slot, so the glide still lands correctly.
   Another option is to cap the wordmark's Dynamic Type size at `.accessibility1`.

## Not re-checked

- On-device launch time (item 4) and frame pacing: the simulator's pre-`main`
  time dominates. The in-app pacing log is DEBUG only.
- Reduce Motion: `simctl` cannot toggle it. The source (0.35 s crossfade,
  no idle event, static art plus spinner on Connect your Mac) matches the spec.
- The GitHub OAuth app name and anything after a real sign-in (listed as
  source-reviewed above).
