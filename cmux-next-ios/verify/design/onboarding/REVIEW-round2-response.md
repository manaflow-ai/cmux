# Response to the round 2 review

Implementer's round 3, 2026-10-14. These items answer `REVIEW-round2.md`.
Captures are in `round3/`. They come from a Production simulator build (one
headless iPhone 17 Pro, iOS 27.0, deleted afterwards).

| # | Item | Status | Artifact |
| --- | --- | --- | --- |
| 1 | Sign-in icons scale with their labels at the largest text size | **Done** | `round3/welcome-ax5-dark.png`, `round3/welcome-ax5-light.png`, and `round3/welcome-default-light.png` (unchanged at the default size) |
| 2 | `Colors.swift`: light error red contrast | **Done** | The `dangerText` comment now says 5.38:1 (#D70015 on white) |
| 3 | 0.3 s launch-screen hold | **Unchanged, as asked** | see below |

## 1. Sign-in icons

- **Icons:** each row's icon is `@ScaledMetric(relativeTo: .headline)`. It is
  18 pt at the default size and capped at 28 pt. The Apple and envelope
  symbols follow it at ±1 pt.
- **Icon slot:** scales the same way, from 22 pt to a cap of 30 pt.
- **Side padding:** at accessibility sizes the row's side padding drops from
  20 to 16 pt. Each label then keeps the same width as before and still wraps
  to two lines. Without that change, the larger icon pushed the labels to
  three lines.
- **Default size:** the rows are unchanged (18 pt icon in a 22 pt slot, 20 pt
  padding).

## 3. The 0.3 s hold

`WelcomeIntroClock.launchCrossfade` stays at 0.3 s.

Your no-hold runs show the system crossfade below 10% by 0.217 s, so the hold
could probably be trimmed to about 0.22 s. That change waits for an on-device
measurement of the launch-screen crossfade and pre-`main` time. The simulator
numbers are not a safe basis for it.

## Still deferred

The "Get cmux for Mac" link on Connect your Mac waits on the user's decision.
The spec's `https://cmux.com/download` returns 404, and the Mac app with
Settings → Mobile → "Allow iPhone Connections" is not released yet.
