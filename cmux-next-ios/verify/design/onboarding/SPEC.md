# Signed-out and first-run design spec

Designer pass, 2026-10-13. Scope: Welcome intro, sign-in (Apple, Google, GitHub,
email code), the team or personal choice and its loading state, Connect your
Mac, notifications, and sign-out/start-over during setup.

## What was looked at

- Build: Production simulator app `20261014-a074414f18-prod`
  (`dev.cmux.mobile.prod`, 0.1.0 (38238), source `a074414f18`; the onboarding
  sources are unchanged on `origin/feat-cnx-ios` `f76bbbe105`).
- Simulator: one headless iPhone 17 Pro, iOS 27.0, 402 x 874 pt, 3x. Simulator.app
  was never opened. Taps went through `axe` (HID injection, no window). Deleted
  afterwards.
- Captured (in `screens/`): the welcome intro recorded in dark and light
  (`welcome-{dark,light}-402w.mp4`, re-encoded at 402 px wide), every signed-out
  screen reachable without an account, the Apple, Google and GitHub sign-in
  attempts (each cancelled before any account step), the email sheet empty,
  invalid and valid (not submitted), the error state, and the largest
  accessibility size (AX5) in both appearances.
- Reference: the user's Claude recording (`~/Downloads/ScreenRecording_10-13-2026
  11-10-58_1.MP4`, already broken down in `verify/login-claude-reference.md`), a
  ChatGPT welcome gallery capture, and the ChatGPT Codex setup screens in
  `~/Downloads/cmux-native-references/ChatGPT/` (05, 09, 10, 11).
- **Source-reviewed only** (needs a real account): the email code step, the team
  or personal choice (loading, failed, create, choose), Connect your Mac,
  notifications, and the setup sign-out footer. Sources: `CmuxMobileOnboarding/Welcome.swift`,
  `WelcomeArt.swift`, `EmailSignIn.swift`, `Setup.swift`, `CmuxMobileDesign/ConnectMac.swift`,
  `CmuxMobileShell/RootView.swift`, `CmuxMobileAuth/CmuxMobileAuthModel.swift`.

**Video timing:** the host's load average was 186 to 313 during capture. The
simulator recorder repeated frames under that load (367 of 582 frames at 60 fps
were duplicates), and one 10 fps sample shows the intro going backwards for a
frame. Positions, sizes and order are reliable. Exact durations and smoothness
from these videos are not. Each timing below says where it comes from:
`video` (± 0.1 s), `source` (the code's constants) or `ref` (Claude).

Coordinates are points on a 402 x 874 pt screen (safe area: 62 pt top, 34 pt
bottom). Pixel measurements were divided by 3.

## Images

| File | Shows |
| --- | --- |
| `img/01-rest-vs-claude-chatgpt.png` | Settled welcome: Claude, ChatGPT, cmux dark, cmux light |
| `img/02-intro-timeline-vs-claude.png` | Claude vs cmux dark and light at +0, 0.1, 0.25, 0.5, 1, 1.5, 2.5, 3.5, 5, 6.5 s after the handoff |
| `img/03-handoff-ghost-chevron-60fps.png` | 16 frames at 60 fps from the handoff: a second, fading chevron stays at the launch position behind the headline |
| `img/04-error-layout-shift.png` | Apple sign-in fails in Production; the whole stack jumps 26 pt |
| `img/05-ax5-welcome-email.png` | AX5: truncated buttons and headline, lockup under the status bar, legal text off screen, clipped email field |
| `img/06-oauth-branding.png` | System alert says "CmuxMobileApp"; GitHub page says "cmux-agent" |
| `img/07-email-vs-claude.png` | Claude's inline email field vs the cmux email sheet |
| `img/08-idle-pulse-light.png` | The idle pulse: loose dots with no path |
| `img/09-codex-setup-refs.png` | ChatGPT Codex pairing and setup screens (reference for setup pages) |
| `screens/NN-*.png` | Every capture at 402 px wide |

## Priority list

| # | Level | Screen | Change |
| --- | --- | --- | --- |
| 1 | Blocker | Welcome | Hide "Continue with Apple" unless the build is TestFlight; in Production it fails at once with "Something went wrong" |
| 2 | Blocker | Welcome, email | Make the whole signed-out flow work at AX5: scroll, wrap labels, hide the art, keep the lockup below the status bar |
| 3 | Blocker | Setup: notifications | Skip the step on builds that can't get push (`CmuxMobilePush = NO`, as in this Production build) and when permission is already decided |
| 4 | Major | Launch → Welcome | Leave the launch mark within 0.35 s; it waits about 1.45 s for auth today |
| 5 | Major | Launch → Welcome | Remove the ghost chevron (the launch view's own fade-and-scale removal still runs) |
| 6 | Major | Welcome | Show the controls together within 0.25 s, with no stagger and no rise |
| 7 | Major | Welcome art | Replace the branching network with one thread and one traveling dot; the network now crosses the phone outline |
| 8 | Major | Welcome | Show sign-in errors without moving the layout, with copy that names the provider |
| 9 | Major | Setup: team | Make "Personal" a real choice that is always first, with the title shown during loading and skeleton team rows under it |
| 10 | Major | System alert, GitHub | Name the app "cmux" in `CFBundleName` and the GitHub OAuth app (now "CmuxMobileApp" and "cmux-agent") |
| 11 | Major | Welcome | Make the legal text readable: 2.27:1 contrast today, needs 4.5:1 |
| 12 | Major | Connect your Mac | Reuse the welcome art and show it waiting; add a "Get cmux for Mac" path |
| 13 | Polish | Welcome | Change the idle pulse to a single idle event 4 s after settling, then rest |
| 14 | Polish | Email sheet | Change the copy so the title doesn't repeat the button; let the field and CTA grow with text size |
| 15 | Polish | Code step | Keep the verify spinner inside the code boxes |
| 16 | Polish | Setup pages | Use lighter page titles (title2 semibold) and 24 pt above the footer |
| 17 | Polish | Welcome | Change the button pitch from 52 + 10 to 50 + 8 so three rows sit like Claude's |

---

## 1. Launch → Welcome handoff

### Now (video, `img/02`, `img/03`)

- The launch chevron is centered (72 pt) on `bg` from about 0.83 s after launch.
  It stays there until about 2.28 s (video): **about 1.45 s of a static mark**.
  Claude's launch screen lasts 0.57 s (ref). Screenshots taken directly (not
  through the recorder) agree: the mark was still centered at 1.2, 1.8 and
  2.35 s after `simctl launch`.
- Cause (source): `RootView` keeps `LaunchMarkView` until `auth.isResolved`. A
  fresh install with no stored session still waits for session restore.
- **Ghost chevron.** For about 16 frames at 60 fps (about 0.27 s) after the
  handoff, a second chevron stays at the launch position and fades out while the
  real one glides up. It sits behind "Your Macs, in your pocket." (`img/03`;
  also the +0.1 s cell in `img/02`). Earlier notes blamed the encoder. The fade
  length matches `LaunchMarkView`'s removal transition,
  `.opacity.combined(with: .scale(0.92)).animation(snap)` (0.25 s). An
  animation attached to a transition still runs inside the `disablesAnimations`
  transaction that `RootView` uses for the cut.

### Spec

- Decide "signed out" without waiting on the network. If there is no stored
  refresh token, `isResolved` is true on the first frame. If a session is
  stored, the handoff waits at most **0.5 s** for restore, then goes to the
  shell, which shows its own loading state. Target: launch mark visible
  **≤ 0.35 s** on a signed-out cold launch.
- The welcome path must be a true cut: give `LaunchMarkView` `.transition(.identity)`
  when the destination is `.welcome`. Keep the fade only for the
  shell and setup destinations. Acceptance: in a 60 fps capture, exactly one
  chevron is visible in every frame from the handoff on.

## 2. Welcome

### Now (`img/01`, `screens/01`, `screens/13`, axe frames)

| Element | Now | Claude (ref) |
| --- | --- | --- |
| Background | `bg` #000000 / #FFFFFF | #151515 |
| Lockup | 22 pt chevron + "cmux" (`welcomeWordmark`, title2 semibold); frame y 68-94 | 24 pt; center y ≈ 82 |
| Art | 291 x 233 pt (`WelcomeArt.size` 260 x 208 x 1.12); Mac + phone line art, 3.3 pt stroke | 175 x 175 pt; one hand-drawn line, 4 pt |
| Headline | "Your Macs, in your pocket." `welcomeTitle` (title, serif), y 443-477 | serif ≈ 28 pt, about 40 pt under the art |
| Buttons | 4 x 52 pt capsules, gap 10, side 20; y 567-805 | 2 x 48 pt pills + 48 pt email field, gap 8, side 16 |
| Legal | caption2, `label3` (#47474A on black = **2.27:1**), y 819-832 | ≈ 12 pt gray (≈ 6:1), underlined links |

Problems:

1. **Apple in Production (blocker).** Tapping "Continue with Apple" fails at once with
   "Something went wrong. Try again." (`screens/06`, `screens/15`). The control
   exists but cannot work. The user wants Apple only in TestFlight.
2. **Controls arrive slowly.** Source: headline 0.08-0.5 s, buttons 0.12-0.655 s
   with a 45 ms stagger and a 14 pt rise, legal 0.35-0.75 s. Video: buttons
   still at about 60% at +0.5 s. Claude: everything is in by +0.12 s with no
   stagger and no rise, and the buttons start at about 35% opacity, so the
   screen never looks empty.
3. **The art's network collides with the phone.** At +3.5 to +5 s (`img/02`
   dark row) the branching network crosses the phone's outline, and one edge
   runs through the phone screen. It reads as a molecule or a blockchain
   graphic, not "my Mac talking to my phone". Claude's accent is one object (a
   ball on a string) in one place.
4. **Idle pulse reads as dust** (`img/08`): three dots drift above the devices
   with no visible path, then vanish. It runs 4 s after settling and every 9 s
   after that, forever.
5. **Error shifts the layout** (`img/04`): the red line is inserted between the
   buttons and the legal text, so the headline and all buttons jump up 26 pt
   (heading y 443 → 430, Apple 567 → 541). The copy is generic.
6. **Legal text contrast** is 2.27:1 (fails WCAG AA); links are 6.36:1.
7. **Light-mode secondary pills** are `fill` (black 5%) on white. They read as
   disabled next to the black Apple pill.
8. **Frame pacing (unconfirmed).** The recording shows a 23-frame stall (about
   0.38 s) just as the line drawing starts (+0.6 s), and a 13-frame stall at
   about +2.5 s. With load at 186-313, this may be the recorder. Check on an idle
   host with the DEBUG pacing log (`dev.cmux.mobile` / `welcome`) before changing code for it.

### Spec: layout (402 x 874 pt; scale proportionally)

Top to bottom, inside the safe area:

| Element | Spec |
| --- | --- |
| Background | `bg` (keep #000; on OLED it matches the rest of the app. #151515 is only Claude's brand) |
| Lockup | Top edge 8 pt below the safe area (center y ≈ 81). Chevron 22 pt, 7 pt gap, "cmux" `welcomeWordmark`, `label` |
| Hero group | Art + headline, centered vertically in the space between the lockup and the button stack, then raised 16 pt (optical center) |
| Art | 260 x 208 pt (drop the 1.12 scale; the art is then 1.5x Claude's area, not 2.2x) |
| Art → headline | 32 pt |
| Headline | Unchanged copy and font (`welcomeTitle`, serif title, `label`), centered, max 2 lines, side margin 20 |
| Error slot | Overlay, no layout space. See "Errors" below |
| Buttons | Production: Google, GitHub, email (3 rows). TestFlight: Apple, Google, GitHub, email. Height 50 pt (a new `ctaWelcomeHeight`; it must grow with Dynamic Type, see AX), gap 8, side margin 20 |
| Buttons → legal | 16 pt |
| Legal | `footnote` (13 pt), `label2`, links `label` + underline, centered, max width 340, bottom 8 pt above the safe area |

Button styles:

- First row (Apple in TestFlight, Google in Production): `accent` fill,
  `onAccent` text (white pill in dark, black in light).
- Other rows, dark: `surface` (#1C1C1E) fill, `label` text (as now).
- Other rows, light: `bg` (white) fill with a 1 pt `separator` (#C6C6C8)
  capsule stroke, `label` text. This replaces the 5% gray fill.
- Icon 18 pt in a 22 pt slot, 10 pt before the title; title `cta` (headline,
  17 pt semibold). Pressed: 0.98 scale and 0.85 opacity with `snap` (as now).
- Busy: spinner replaces that row's icon; the other rows go to 50% (as now).

Gate Apple with a build key, the way `CmuxMobilePush` already works: add `CmuxMobileAppleSignIn`
(`$(CMUX_MOBILE_APPLE_SIGN_IN)`, YES only in the TestFlight configuration) and read it
in `BuildCapabilities`. When NO, the Apple row is not built at all.

### Spec: errors

- Copy names the provider: "Couldn't sign in with Google. Try again." (the
  same for GitHub and Apple). Keep the specific messages from
  `CmuxMobileAuthModel.message(for:)` when they exist (network: "You're offline.
  Check your connection and try again.").
- Placement: a single line of `footnote` `danger` text, centered, overlaid in
  the empty band 12 pt above the first button. The band is at least 60 pt
  tall at rest, so it fits without moving anything. If the text needs two lines,
  it grows upward only.
- Motion: in with opacity 0 → 1 and y +6 → 0, `snap` (0.25 s). It clears
  (opacity out, `snap`) on the next tap of any sign-in row. Error haptic as now.
- Cancel stays silent (verified: cancelling the Google and GitHub sheets
  clears the error and shows nothing).

### Spec: intro motion (one clock, as now; times since the handoff)

Keep the structure: one `TimelineView` clock, the launch mark becoming the
lockup, controls first, then the art plays by itself. Change the timings and
the accent act.

| Time (s) | What | Curve |
| --- | --- | --- |
| 0 | Hard cut from the launch view (one chevron only). The headline and buttons are already at 35% opacity | cut |
| 0-0.45 | Chevron glides 72 → 22 pt into the lockup and takes the icon gradient (as now: `outQuint` over 0.04-0.68 → 0-0.45) | outQuint |
| 0-0.22 | Headline, buttons and legal go 35% → 100% opacity together. No stagger, no blur, no rise | easeOut |
| 0.15-0.5 | "cmux" wordmark fades in, x -8 → 0 (as now, earlier) | outQuint |
| 0.1-1.3 | Mac draws as one pen stroke (screen, then base) | easeInOut |
| 0.7-1.5 | Phone draws | easeInOut |
| 1.3-1.6 | `>_` prompt types in on the Mac screen (as now) | easeOut |
| 1.6-2.2 | **Thread**: one quadratic curve grows from the prompt's cursor up and over the gap to the phone's screen center. 2.5 pt, round caps, icon gradient along x (#06CDFE → #2AA0F9 → #5170F3). The control point is 40 pt above the higher endpoint, so the curve never crosses either outline | easeInOut |
| 2.2-3.2 | **Dot**: a 7 pt gradient dot rides the thread from the Mac to the phone, with a slight speed-up in the middle | easeInOut |
| 3.2-3.7 | The dot enters the phone and grows into the chevron (0 → 26 pt) with a soft glow | spring, duration 0.5, bounce 0.25 |
| 3.6-4.1 | Thread retracts from the Mac end toward the phone and disappears | easeIn |
| 4.1 | Rest. Timeline stops (as now) | |

- Total about 4.1 s (Claude: draw, bloom, sway, fold, settle in about 6.5 s;
  the user's "5 s" bar). Nothing outside the two device outlines and the
  thread's arc ever moves.
- **Idle**: one event, 4 s after rest. The thread re-draws at 35% opacity
  (0.5 s), a dot travels it (1.0 s), and the phone chevron's glow beats once
  (0.4 s); then the thread fades (0.3 s). No repeats, as in Claude: one idle
  event, then stillness. Remove the 9 s loop.
- Reduce Motion: as now (0.35 s crossfade to the settled state; no idle event).
- Interrupts: as now (tapping any row mid-intro works; verified by the earlier
  `interrupt.png` pass).
- Pacing target: no frame over 2x the display interval after the handoff,
  measured in the app on an idle host.

### Spec: largest text (AX1-AX5) (blocker; `img/05`)

Now at AX5: the lockup is drawn at y = -3 (under the status bar), the headline
is truncated to "Your Macs, i…", every button reads "Continue wi…", and the
legal text runs off the bottom (y 759 + 144 > 874). Nothing scrolls.

- Wrap the content in a `ScrollView` that only scrolls when it overflows
  (`.scrollBounceBehavior(.basedOnSize)`).
- At `dynamicTypeSize.isAccessibilitySize`: hide the art (keep the lockup and
  the headline), let the headline wrap with no line limit, put the lockup at
  the top of the scroll content (below the safe area, never under the status
  bar), and give buttons `minHeight` 50 with 12 pt vertical padding. Labels
  wrap to two lines, centered, with the icon kept on the first line.
- The legal text wraps freely and is reachable by scrolling.

## 3. Email sign-in sheet

### Now (`screens/02-04`, `screens/14`, `screens/18`, `img/07`)

- A large sheet: Close (36 pt glass, top left), title "Continue with email"
  (`sheetTitle`), "We'll send you a 6-digit code.", the field (52 pt,
  `cmuxMobileInputField`) at y 223, and "Send code" pinned at the bottom. Send code is
  disabled (gray) until the address is valid. Light mode uses a white sheet
  (correct).
- The title repeats the button the user just tapped.
- AX5: the field keeps its 52 pt height and clips its text. "Send code" clips
  too.

### Spec

Keep a sheet; the user wants the welcome itself to stay minimal, so don't
adopt Claude's inline field.

- Title: "What's your email?" (`sheetTitle`). Subtitle: "We'll send you a code
  to sign in." (`rowSubtitle`, `label2`, 6 pt below).
- Field: 20 pt below. Height = max(52, text height + 2 x 14 pt) so it grows with
  Dynamic Type; placeholder "name@example.com" in `label3` (as now).
- CTA: "Continue" (the next screen tells the user that a code was sent). It sits 12 pt above
  the keyboard, or above the safe area when no keyboard shows (as now). Height
  grows with text like the welcome buttons. Disabled: 40% opacity, still shaped.
- Sending: spinner inside the CTA (as now). Errors: under the field, `meta`,
  `danger` (as now).

## 4. Email code step (source-reviewed)

- Copy is right: "Check your email" / "Enter the code we sent to {email}."
- Wrong code: shake, clear, error line, haptic. Good.
- Resend shows "Resend in 0:30" at 40% opacity and counts down. This is not a
  dead control because it states when it will work. Keep it.
- Change: while verifying, the spinner is drawn at the boxes' center + 52 pt,
  where it collides with the "Resend" line 20 pt below the boxes. Instead, dim
  the boxes to 40% and center a regular `ProgressView` on them.
- Code boxes must grow with Dynamic Type; at AX sizes, let them wrap to two rows
  of three.

## 5. Team or personal choice, with loading (source-reviewed)

### Now

- Shown only when the account doesn't have exactly one team
  (`planSetup`: `count != 1`).
- Loading: a full page of 3 skeleton rows, 72 pt from the top, with **no title
  and no explanation**. `skeletonDelay` (250 ms) shows a blank page first.
- No teams: "Create your team" with a name field, "Create team" and "Not now".
  Personal is only implied by "Not now".
- Teams: "Choose a team" lists `store.teams`. The personal space joins that list
  only when a Mac already lives there, so a user with a team and no personal
  Mac cannot choose Personal.
- Failure: a full-page "Couldn't load your teams" with Retry blocks everything,
  Personal included.
- Good: "Create Team" never shows as a placeholder while loading, and the
  sign-out footer shows on loading and failure.

### Spec: one page, "Choose a space"

| Element | Spec |
| --- | --- |
| Title | "Choose a space" (`title2` semibold, see 8), leading, 12 pt below the nav bar. Drawn on the first frame, also while loading |
| Subtitle | "Your Macs show up in the space they're signed in to. You can switch any time from the sidebar." `rowSubtitle`, `label2`, 6 pt below, 16 pt above the list |
| Row 1, always | "Personal": avatar `person.fill` on `fillSelected`, 36 pt, radius 10; subtitle "Just you" plus Mac dots when known. It needs only the user id, so it is never a skeleton |
| Team rows | `SidebarTeamRow` (60 pt) as now |
| Last row, loaded only | "Create a team": 36 pt avatar with a dashed 1.5 pt `separator` border and `plus`; pushes the create page |
| Loading | Under Personal: 2 skeleton team rows (`SkeletonList`, 36 pt square) with shimmer, from the first frame (no 250 ms blank, since the title is already there). No "Create a team" row |
| Loaded | The skeletons crossfade into the real rows (`smooth`, 0.35 s). The real rows take the skeletons' positions, so nothing jumps. "Create a team" fades in last (0.1 s later) |
| Failed | In place of the skeletons: one inline row, "Couldn't load your teams." plus a "Retry" text button (`label`, semibold). Personal stays selectable |
| Selection | Tap selects and advances (as now), with a selection haptic |

Create page (pushed): the current "Create your team" page without "Not now",
because Back returns to the choice. The CTA "Create team" is disabled until the
name is non-empty (as now).

## 6. Connect your Mac (source-reviewed)

### Now

- SF Symbol `desktopcomputer` 48 pt, title "Connect your Mac" (`heroTitle`, 28 pt
  bold), two numbered steps, a live status line ("Waiting for your Mac…" with a
  spinner → "{Mac} is online" with a green check), "Not now" → "Continue" when
  a Mac appears. The copy says **Settings → Mobile → Allow iPhone Connections**,
  as required.
- There is no path for a user who doesn't have cmux on the Mac yet (Codex
  offers "Email me a download link", `img/09`).

### Spec

- Art: the welcome's settled Mac + phone line art at 200 pt wide (same
  `WelcomeArt` paths), not an SF Symbol, so setup continues the welcome.
- Waiting: every 2.4 s, the idle thread-and-dot event from the welcome plays at
  35% (1.5 s). Reduce Motion: static art plus the spinner.
- Found: the dot arrives and the phone chevron blooms (spring 0.5 s, bounce
  0.25), a success haptic plays, the status flips (as now), and "Not now" crossfades into
  the "Continue" primary (`snappy`).
- Title "Connect your Mac" in the setup title style (see 8). Steps: unchanged
  copy.
- Add under the steps (`rowSubtitle`, `label2`): "Don't have cmux on your Mac?"
  plus a "Get cmux for Mac" text button that opens a share sheet with
  `https://cmux.com/download`, so the user can AirDrop or email it to the Mac.
- Before shipping, confirm the Mac app's setting is literally named "Allow iPhone
  Connections" under Settings → Mobile.

## 7. Notifications (source-reviewed)

### Now

The step always runs. "Turn on notifications" asks the system and, if allowed,
registers for push. On builds without push (`CmuxMobilePush = NO`, true for the
Production build captured here), the step promises alerts that never arrive.
Settings already handles this case ("This build can't receive notifications
from your Macs. The TestFlight build can."); setup does not.

### Spec

- Plan the step only if `BuildCapabilities.current.push` is true **and**
  `UNUserNotificationCenter` reports `.notDetermined`. Otherwise skip it.
- Gate `registerForRemoteNotifications()` on `push`, as Settings does.
- Copy is fine. Use the setup page style (see 8).

## 8. Setup pages and start-over (source-reviewed)

- Page template (`SetupPage`): symbol 48 → 40 pt, `label`. Title `heroTitle`
  (28 pt bold) → `title2` semibold (22 pt), centered; Codex uses about 20 pt
  semibold. Body max width 340, centered. Actions: primary capsule (52 pt) and
  then the secondary text button (44 pt hit area), 10 pt apart.
- Sign-out footer: keep it on every page, as the user requires ("Signed in as
  {email} · Sign out", `meta`, `label2`; "Sign out" semibold `label`), but put
  24 pt between the last action and the footer. Today "Not now" and "Sign out"
  are about 18 pt apart and read as one stack of text links.
- The confirmation is right as it is: "Sign out and start over?" / "You can sign in again
  with this or another account." / destructive "Sign Out".
- After sign-out, Welcome crossfades in already settled (source: the intro
  clock is set to `.infinity` when Welcome disappears). The comment in
  `RootView.signedOut()` says the intro replays. Keep the settled behavior and
  fix the comment.

## 9. Names outside the app UI

- The system sheet shown before Google, GitHub and Apple says **"CmuxMobileApp" Wants to
  Use…** (`img/06`). `CFBundleName` is `CmuxMobileApp`; the display name is
  `cmux mobile`. Set `CFBundleName` (`PRODUCT_NAME`) to "cmux" for Production and
  TestFlight. The system sheet uses `CFBundleName`.
- The GitHub authorize page says "continue to **cmux-agent**". Rename the GitHub
  OAuth app used by the production sign-in project to "cmux" (the chevron icon
  is already correct). This is a GitHub and sign-in project setting, not app
  code.

## Not captured

- Anything after a real sign-in: the code step, the team or personal choice (all
  phases), Connect your Mac, notifications and the setup footer. No account was
  created; these sections are source-reviewed.
- Reduce Motion and the in-app frame-pacing log: Production has no DEBUG
  freeze or hold arguments, and `simctl` cannot toggle Reduce Motion.
- Exact intro durations and smoothness: the recorder was unreliable under host
  load 186-313 (see the timing note above).
- Fresh public Claude, ChatGPT and Grok onboarding videos: none were found. The
  user's Claude recording and the earlier ChatGPT gallery capture were used.
- The ChatGPT reference in `img/01` is a gallery screenshot, not a current App
  Store build.
