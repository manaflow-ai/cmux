# Claude iOS welcome: frame-by-frame reference

Source: a 27 s screen recording of the Claude iOS app, signed out, on the user's
iPhone (1320 x 2868, 60 fps, dark mode only). It is kept outside the repository.
Frames were split with ffmpeg at 2 fps (overview), 10 fps (0.8-10.4 s and
10.3-13.5 s) and 60 fps (1.25-1.75 s, the handoff). Points below are pixels / 3
(440 x 956 pt screen). Times are video time; the intro starts at the handoff,
**h = 1.383 s**.

## Layout at rest (15 s)

| Element | Measure |
| --- | --- |
| Background | `#151515` (not pure black) |
| Lockup | "✳ Claude" centered, about 24 pt, center y about 82 pt; orange asterisk, white serif wordmark |
| Illustration | One white hand-drawn line (about 4 pt, round caps): a hand holding a string, a face profile. An orange (`#D46A4D`) ball on the string. About 175 x 175 pt, center y about 375 pt |
| Headline | "The AI for problem solvers", serif display, regular, about 28 pt, white, centered, about 40 pt under the illustration |
| Buttons | 48 pt capsules, 16 pt side margins, 8 pt gaps: "Continue with Google" (white), "Continue with Apple" (white), then an email text field (`#1D1D1D` fill, hairline border) instead of a third button |
| Legal | `caption`-size gray text, two lines, underlined links, about 20 pt under the field |
| Spacing | Lockup at the top, illustration and headline centered in the middle, buttons pinned to the bottom with a large empty band above them |

## Timeline

| Video time | Since h | What happens | Curve |
| --- | --- | --- | --- |
| 0.0-0.8 | | Springboard, app-open zoom | System |
| 0.8-1.37 | | Launch screen: "✳ Claude" large (about 36 pt) at the screen center, "ANTHROPIC" small at the bottom | Static |
| 1.383 | 0 | One-frame cut to the welcome. The wordmark is already about a quarter of the way up; headline and buttons at about 35% opacity, buttons gray | Cut |
| 1.38-1.55 | 0-0.17 | Wordmark glides up and shrinks into the top lockup | Fast ease-out (most of the travel in 3 frames) |
| 1.38-1.50 | 0-0.12 | Headline, buttons and legal fade to full opacity; "ANTHROPIC" fades out. No stagger, no rise | Ease-out |
| 1.42 | 0.04 | A white dot appears at the top of the face line | |
| 1.42-2.30 | 0.04-0.9 | The face profile is drawn top to bottom as a pen stroke | Ease in-out; slow start (1.4-1.75 only a short arc) |
| 1.9-2.3 | 0.5-0.9 | An orange dot appears left of the face and swells | Ease-out |
| 2.3-2.9 | 0.9-1.5 | The line continues into the hand and fingers; the orange dot splits into two linked dots | |
| 2.9-3.9 | 1.5-2.5 | An orange network blooms out of the hand: straight edges grow out, each ending in a dot that pops, about 10 nodes, reaching past the figure | Each edge about 0.3 s, staggered |
| 3.9-5.6 | 2.5-4.2 | The network sways gently: nodes drift a few points, edges stretch | Slow sine |
| 5.7-6.4 | 4.3-5.0 | The network folds back into the hand and shrinks to one small dot | Ease-in |
| 6.4-7.0 | 5.0-5.6 | The dot sits by the fingers; the hand curls its string into a loop | |
| 7.0-7.9 | 5.6-6.5 | The string rises from the hand and the dot rides up it, swelling into the ball | Ease-out, small overshoot |
| 7.9-10.5 | 6.5-9.1 | Rest | |
| 10.5-12.5 | 9.1-11.1 | Idle event: the ball deflates and drifts up-left as a trail of shrinking dots that fade out | Ease-in |
| 12.5-13.5 | 11.1-12.1 | Dots reappear by the hand, merge and re-form the ball | Ease-out |
| 13.5-27 | 12.1- | Rest; no further motion in the recording | |

## What to take from it

- The controls never wait for the animation. Text and buttons are fully in about 0.12 s after
  the handoff; the illustration plays on its own over the next 6.5 s.
- The handoff is continuous: the launch wordmark becomes the lockup; nothing pops in.
- One illustration carries the brand: white line art plus one accent color. The accent element
  (network, then ball) is where all the motion is.
- Choreography in acts: draw (about 1.5 s), bloom (1 s), breathe (1.7 s), fold (0.7 s), settle
  (1 s). The "5 second" feel is draw + bloom + breathe + fold.
- At rest the screen is still. One idle event (dissolve and re-form) happens a few seconds after
  the intro, then nothing for the rest of the recording.
- Typography: a serif display face for the headline and wordmark, sans for buttons and legal.

## cmux equivalent (SPEC 5.2)

The same structure with cmux's identity: the launch chevron glides into a "> cmux" lockup; a
Mac and an iPhone are drawn as one white line; a gradient network (the app icon's
cyan-to-indigo) grows from a `>_` prompt on the Mac to the phone, sways, folds into the
phone and blooms as the cmux chevron. Text and buttons are in by 0.65 s; the intro settles at
5.2 s. Idle: a short sync pulse (three dots along the network path, a chevron beat) 4 s after
settling and every 9 s. The headline uses the system serif (New York) instead of a brand face.
