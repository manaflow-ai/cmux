# Login verification (welcome redesign)

Date: 2026-10-13. Branch `feat-cnx-ios-login`. Evidence (git-ignored) is in
`cmux-next-ios/verify/evidence/2026-10-13/login/`.

## Feedback

"I dislike everything in the login screen that comes above the continue
buttons. Examples of login screens I like are Claude's and ChatGPT."

## References

Neither app's signed-out screen was in `~/Downloads/cmux-native-references/`
(all captures there are signed in), so the references come from public galleries:

- Claude iOS welcome (Refero, via Pinterest): "✳ Claude" wordmark at the top, one
  serif headline ("Do your best work with Claude"), then the sign-in controls and
  legal text. Nothing else.
- ChatGPT iOS welcome (Banani): one centered "ChatGPT ●" line on a plain field
  that cycles a few words, then a stack of equal pills: Continue with Apple
  (white, first), Continue with Google, Sign up with email, Log in.

Both are copied into `evidence/.../refs/` only for the comparison strip.

## Before and after

- Before: a 40 pt mark, a mono "terminal" card typing lines and a chat bubble
  on a 6 s loop, a leading-aligned headline and a second line of feature copy.
- After: the cmux chevron (60 pt, the app icon's cyan-to-indigo gradient with a
  soft glow) and one centered line, "Your Macs, in your pocket.", centered in the
  space above the buttons. The button stack is unchanged in order and size
  (Apple first, then Google, GitHub, email; all 52 pt capsules), as in ChatGPT.
- Launch to welcome: the launch mark becomes the hero mark. Welcome draws the
  mark at the launch screen's size and center on its first frame (the root
  swaps without a fade). The mark then glides up, shrinks 72 → 60 and takes the
  gradient. The headline un-blurs and rises, and the buttons stagger in. After
  that, a slow glow breathe is the only motion. Reduce Motion uses crossfades.
- Email sheet, light mode: the field and code boxes were the same gray as the
  sheet and were invisible. The sheet is now white in light, as in Claude and
  ChatGPT; dark is unchanged.

## How it was run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
verify/build.sh <ios26 udid> <ios27 udid>          # xcodegen + simulator build + install
verify/record-login.sh <udid> s27 verify/evidence/2026-10-13/login   # welcome + email, dark and light
CMUX_MOBILE_CLEAR_AUTH=1 CMUX_MOBILE_MOCK_AUTH=1 CMUX_MOBILE_RECORD_CODEC=hevc \
  verify/record.sh <udid> .../s27-code-dark.mp4 6 dark -cmux-mobile-email name@example.com
verify/login-montage.sh verify/evidence/2026-10-13/login 2.58   # strips
```

The simulators were headless `cmux-mobile-login-ios26` (iOS 26.5) and `cmux-mobile-login-ios27`
(iOS 27.0), both iPhone 17 Pro. Simulator.app was never opened. Every run
launched signed out with `CMUX_MOBILE_CLEAR_AUTH=1`.

## Results

| Strip | Shows | Result |
| --- | --- | --- |
| `cmp-welcome.png` | Claude, ChatGPT, before, after (dark, light) | Same composition as the references: a mark and one line, then the pill stack and legal text |
| `cmp-matrix.png` | Welcome, email and code steps on iOS 26 and 27, dark and light | Same layout on both OS versions. The light email field and code boxes are now visible |
| `intro-s27-dark.png` | Launch → welcome, 12 frames 80 ms apart | The mark leaves the launch position without a jump, glides up and turns blue. The headline and buttons follow, settling in about 0.8 s |

Recorder artifact: in the videos, the mark seems to leave a faint dark trail at
the launch position for 2 or 3 frames. Screenshots taken during a slowed-down
intro (6 s spring, a temporary local build) show no trail. The trail comes from
the simulator's video encoder, not the app.

## Gaps

- The references are 2024-2026 gallery captures, not fresh captures of the
  current App Store builds.
- With `CMUX_MOBILE_CLEAR_AUTH=1`, the launch mark waits about 2 s for auth to resolve
  before the intro starts. That delay comes from session restore, which was not
  part of this change.
- Apple, Google and GitHub sign-in were not run end to end. The buttons and
  their busy and disabled states are unchanged.

# Pass 2: choreographed intro (Claude reference)

Feedback: "the login doesn't look like Claude's or ChatGPT's, make it more beautiful. like a
5 second animation that Claude has". The Claude recording is decomposed frame by frame in
`verify/login-claude-reference.md`. Evidence (git-ignored) is in
`cmux-next-ios/verify/evidence/2026-10-13/login2/`.

## Change

Welcome now has Claude's structure with cmux's identity (SPEC 5.2): a "> cmux" lockup at the
top, a line-drawn Mac and iPhone with a serif headline in the middle, the unchanged four-button
stack at the bottom. A ~5 s intro runs on one frame-driven clock (`TimelineView` + `Canvas`):
the launch chevron glides into the lockup, text and buttons are in by 0.65 s, the Mac and phone
draw themselves, a gradient network grows from a `>_` prompt to the phone, sways, folds in and
blooms as the chevron. It settles at 5.2 s and the timeline stops. A short sync pulse runs 4 s
later and every 9 s. Reduce Motion crossfades. `CADisableMinimumFrameDurationOnPhone` is set so
ProMotion devices can run it at 120 Hz.

## How it was run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
verify/build.sh <ios26 udid> <ios27 udid>
verify/login-timeline.sh <udid> dark|light <dir>       # frozen intro at 16 exact times
python3 verify/login-compare.py <claude.mp4> 1.383 <dir> <label> ... <out.png>
CMUX_MOBILE_CLEAR_AUTH=1 CMUX_MOBILE_RECORD_CODEC=h264 verify/record.sh <udid> <out.mp4> 14 dark -cmux-mobile-intro-hold 2
```

DEBUG launch arguments for verification: `-cmux-mobile-intro-freeze <s>` holds the intro at a time,
`-cmux-mobile-pulse-freeze <s>` holds the idle pulse, `-cmux-mobile-intro-hold <s>` rests on the launch mark
first. At the end of each intro a DEBUG build logs frame pacing (`dev.cmux.mobile`, category
`welcome`).

## Results

| Artifact | Shows | Result |
| --- | --- | --- |
| `timeline.png` | Claude vs cmux at t = 0 to 6.5 s, iOS 27 and 26, dark and light | Same acts: continuous handoff, controls in first, line drawing, accent bloom, fold, settle |
| `rest-compare.png` | Settled screen: Claude, cmux dark, cmux light | Same composition and weight |
| `interrupt.png` | Email tapped 2.6 s into the intro (`-cmux-mobile-demo onboarding`) | The sheet opens mid-intro; email and code steps work |
| `reduce.png` | Reduce Motion at 0.15 s and 3 s | Crossfade from the launch mark to the settled screen |
| `pulse.png` | Idle pulse at 0.4 to 1.5 s | Dots travel Mac → phone, chevron glow beats |
| `pacing.txt` | In-app frame pacing over the intro, 4 runs | iOS 27: 309-310 frames, p50 16.7 ms, 2-3 frames of 33 ms. iOS 26: one run with 1 frame of 33 ms; one run (dark) with 14 long frames, max 233 ms |

The host's load average was 450-770 during these runs (other sessions' builds and
simulators). The simulator recorder retimed and dropped frames under that load: its videos
showed the intro skipping ahead while the app's own clock and simultaneous screenshots showed
it running in real time. So the timeline sheet uses frozen-time screenshots, and jank is
measured in the app instead of from the video. The 233 ms hitch on iOS 26 is consistent with
host contention; the other three runs were clean at the simulator's 60 Hz.

## Gaps

- Not run on a ProMotion device; 120 Hz is enabled but unverified.
- The Claude reference is dark mode only; cmux light mode follows the same structure.
