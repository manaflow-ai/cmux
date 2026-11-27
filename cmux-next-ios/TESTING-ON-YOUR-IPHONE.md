# Testing cmux on your iPhone

This page answers Leo's question from 2026-11-27: "and then idk what im supposed to be able to do to test and verify on my end
either like faster dev loops and testflight or anything".

## Which app is which

| App on the phone | Bundle id | What it runs | How it gets there | Updates |
|---|---|---|---|---|
| **cmux INTERNAL** (TestFlight) | `dev.cmux.app.internal` | `feat-cmux-next` after recent merges, or an iPhone YOLO stack | TestFlight, internal group | By itself (see below) |
| **cmux Dev** | `dev.cmux.mobile.dev` | One PR, branch or commit you pick | `cmux-next-ios/scripts/try.sh` from a Mac the phone is plugged into or paired with | Each `try.sh` replaces it in place |
| **cmux** (App Store) | `com.cmux.app` | The App Store release | App Store | Releases |

The apps sit side by side, and each one keeps its own sign-in. All of them pair with your NIGHTLY Mac and show your
real account. The NIGHTLY is the Mac app; no iPhone app is called NIGHTLY.

## cmux INTERNAL: every merge, about 30 minutes later

- Every push to `feat-cmux-next` runs `ios-internal-nightly-trigger.yml`.
- It builds and uploads when anything has changed for iOS since the last upload, or after 12 hours with no upload. Uploads are at least 30 minutes apart.
- The "What to Test" text in TestFlight lists the PRs merged since the previous build, one line each.
- Logic: `scripts/ci/ios_internal_builder.py plan`. Design: `plans/cmux-next/ios-testflight-builder-DESIGN.md`.
- While builds keep failing, the trigger waits longer between tries: 30 minutes at first, doubling up to 6 h.

To update: open TestFlight, then cmux INTERNAL, then Install. If TestFlight's automatic updates are on, you don't
need to do anything.

## One PR on your phone: iPhone YOLO (one tap in TestFlight)

An agent or a person can start this from anywhere (lane VMs go through the broker):

```
gh workflow run ios-internal-nightly-trigger.yml --ref feat-cmux-next -f yolo="58841"        # one PR
gh workflow run ios-internal-nightly-trigger.yml --ref feat-cmux-next -f yolo="58841 51471"  # several, stacked
gh workflow run ios-internal-nightly-trigger.yml --ref feat-cmux-next -f yolo=label          # every open PR labelled ios-yolo
```

It merges the PRs onto the `feat-cmux-next` head and pushes the result to `ios-yolo/<stamp>`. Then it builds that
the same way as INTERNAL. Once the build has run and TestFlight has processed it, cmux INTERNAL in TestFlight offers the build. Its "What to Test"
starts with "cmux-next iPhone YOLO" and lists the PRs. A PR that doesn't merge cleanly is left out, and that PR gets
a comment saying so.

The build replaces cmux INTERNAL for every internal tester until the next nightly build replaces it in turn. Ask
in #cmux-ios before you YOLO something risky.

## One PR on your phone, from a Mac: cmux Dev

```
cmux-next-ios/scripts/try.sh 58841        # a PR, branch, commit, or . for this checkout
cmux-next-ios/scripts/try.sh status       # the last tries
```

Run this on the Mac the phone is plugged into or paired with over the network. A fleet Mac builds the app, then your
Mac signs it, installs it as cmux Dev and launches it. Your sign-in and pairing stay. This is the fastest loop: no
TestFlight processing, and only the one PR. Details are in `cmux-next-ios/CLAUDE.md`, "Try a PR on the person's phone".

## Report a bug in one step

**Shake the phone** anywhere in the app, then tap **Copy Logs and Open Report**:

1. The log from this launch, plus the connectivity journal, goes to the clipboard.
2. GitHub's bug report form opens with the app version, the build and iOS already filled in.
3. Paste the log into "Additional context" and say what went wrong.

HQ counts these reports by the "Sent from cmux NEXT Send Feedback" marker. The same two steps are also in Settings,
under About: **Copy Logs**, then **Send feedback**.

If you're on a Mac, you can also tell any agent "file this" with a screenshot. The agent opens the issue for you.
