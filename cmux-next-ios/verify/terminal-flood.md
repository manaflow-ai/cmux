# Terminal under output floods, and three terminal fixes

Branch `feat-cnx-ios-termfix`, 2026-10-14. This page covers findings from the
E2E rig (`verify/e2e-matrix.md` on `feat-cnx-ios-e2erig`):

- #5: an output flood froze the app.
- #10: after `clear` or scrollback, typing did not bring the prompt back.
- #7: the Files and Links preview stayed blank.
- #12: the key bar's accessibility frames pointed at the wrong keys.

## #5 Output flood

### Cause

Every output chunk did all of this on the main thread:

- JSON decode, base64 decode and the alternate screen scan in
  `DaemonTerminalSession`;
- the files-and-links regex scan;
- the row shift;
- a main-queue hop back after Ghostty parsed the chunk, with a cursor probe and
  a document update;
- a draw request.

Ghostty presented two frames per chunk, and each presented frame hashed the
whole surface (`presentedRowSignatures`), allocating an array per row.

At about 300 chunks a second the main thread fell behind:

- the backlog kept the app busy after the writer stopped;
- touches waited behind it for seconds.

### What changed

**Decoding off the main thread.** `DaemonTerminalSession` decodes event lines
on a detached task (`DaemonTerminalEventParser`). It hands them to the main
actor in batches, one main-queue hop per batch (`DaemonTerminalInbox`).

**Backpressure.** The reader stops reading the channel in two cases:

- more than 4 MiB is waiting for the main actor;
- the screen asked it to pause.

The screen asks for a pause through the new
`TerminalSession.setOutputPaused(_:)`. A session that cannot hold its program
back ignores the call.

`DaemonClient`'s own event stream is still unbounded; that stream belongs to
the transport.

**One feed per display frame.** The terminal screen queues output in
`TerminalOutputQueue` and feeds Ghostty at most once per display frame.

- A `CADisplayLink` runs only while output is waiting.
- Each batch is at most 256 KiB.
- One batch is in flight at a time.
- A batch can go at once if nothing was fed in the current frame, so a
  keystroke echo is not held back to the next frame.
- An alternate screen switch is applied in order, after the bytes before it
  are parsed.
- Above 8 MiB queued, the screen pauses the session, and resumes it below
  2 MiB.

**Other work moved or reduced.**

- The row shift runs on the surface's output queue.
- The files-and-links scan runs on its own queue (`TerminalArtifactCollector`).
- While Files and Links is open, the list is reconciled with the screen at
  most twice a second.
- Row signatures walk the pixels with a pointer and allocate nothing per row.
  They take the same samples and give the same hash.
- Ghostty wakeups queue one tick at a time.

**Kept:** the draw request after each parsed batch. Without it, Ghostty
presents on its own timer, and a keystroke echo took about 3 times longer
(the `exp-norefresh` run).

### Benchmark

The benchmark is a DEBUG-only harness, compiled only into Debug and Demo
builds. Launch the app with `-CmuxMobileFloodBench`. The code is in
`CmuxMobileLive/TerminalFloodBench.swift` and the probe in
`CmuxMobileTerminal/Demo/TerminalBenchProbe.swift`.

What is real:

- `DaemonClient` and `DaemonTerminalSession`, including the input lane;
- the terminal screen and the Ghostty renderer.

What is fake: only the Mac. A fake daemon streams `output` events at a fixed
rate in 4 KiB events, and echoes each `send` behind the output already
queued.

The output is a real PTY capture of `ls -lRG` with colors, 3.4 MB, recorded
with `script` and passed with `-CmuxMobileFloodBenchFile`.

Each run has three phases: 3 s idle, a 10 s flood, then 6 s after the flood.
Each second it records:

- the main thread's CPU time, from `thread_info`;
- main-queue latency, from a ping every 10 ms on a background thread;
- keystroke echo latency: a key every 200 ms on a background timer, measured
  to the first frame presented after Ghostty parsed its echo;
- frames presented;
- bytes processed.

Real touches came from `axe tap` during the flood.

The runs used one headless simulator, `cmux-mobile-termfix` (iPhone 17 Pro,
iOS 26.0), and Xcode 26.

**Results, Demo configuration (optimized, like Production).** Values are
during the flood, before → after.

| Flood | Main thread CPU (ms per s) | Frames presented per s | Echo p50 / p90 / max (ms) |
| --- | --- | --- | --- |
| 10 Mbit/s, recorded PTY | 541 → **161** | 554 → 192 | 3.3 / 5.6 / 8.8 → 19.8 / 21.6 / 23.4 |
| 30 Mbit/s, recorded PTY | 809 → **213** | 1027 → 267 | 6.4 / 35 / 85 → 16.3 / 17.7 / 18.5 |
| Top row rewritten 100 times a second | 141 → **104** | 211 → 168 | 2.7 / 3.3 / 3.8 → 3.8 / 5.5 / 12.2 |

The "after" values come from the final build (`final-*.json`).

"Echo" here is measured to the layer's `contents` change. Before the fix,
frames were presented 550 to 1000 times a second, faster than any display, so
the old echo number is not time to the screen. After the fix, the echo is
shown within the next frame or two of a 120 Hz display. With the keyboard up
(below), the old build fell behind and its echo took seconds.

**Results, Debug configuration (the E2E rig's configuration).** The keyboard
was brought up by a real tap during the flood.

| 10 Mbit/s, recorded PTY | Before | After |
| --- | --- | --- |
| Main thread CPU during the flood | 919 ms per s (max 943) | **278 ms per s** (max 418) |
| Main thread CPU after the writer stopped | 620 ms per s, still busy | **41 ms per s**, idle |
| Bytes processed | 957 KB/s, behind the 1222 KB/s arriving | 1236 KB/s, keeping up |
| Drain after the writer stopped | 4.0 s | within the 1 s sample |
| Keystroke echo p50 / p90 / max | **1552 / 2691 / 3100 ms** | **16 / 17 / 223 ms** |
| `axe tap` round trip, 6 taps | 9564, 6223, 617, 569, 666, 1240 ms | 1579, 961, 607, 753, 616, 683 ms |
| Main-queue ping p99 / max | 41 / 108 ms | 75 / 161 ms, during the keyboard animation |

Without a tap, a Debug run at 10 Mbit/s went from 829 to 210 ms per second of
main thread CPU. The echo p90 went from 98 to 21 ms, and the max from 224 to
22 ms.

The raw JSON is in
`verify/evidence/2026-10-14/termfix/bench/`, which is git-ignored. The names
start with `before-`, `after-` and `exp-`.

### Reproducing

```sh
xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build
xcrun simctl install <udid> /tmp/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app
CLICOLOR_FORCE=1 script -q /tmp/rec.typescript sh -c 'ls -lRG /usr/share/man /System/Library/CoreServices | head -c 4000000'
xcrun simctl launch <udid> dev.cmux.mobile -CmuxMobileFloodBench -CmuxMobileFloodBenchFile /tmp/rec.typescript
# Optional: -CmuxMobileFloodBenchMbps 30, -CmuxMobileFloodBenchMode topline, -CmuxMobileFloodBenchSeconds 14
# Result: <app data>/Documents/flood-bench.json; log lines start with [flood-bench].
```

On the build fleet (agents cannot run xcodebuild on their own Mac), the
simulator step builds the Demo app, records `cat` of a 6 MB file, vim
scrolling and top on the worker, and runs this benchmark on each, with
screenshots:

```sh
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg bench --artifact artifacts/ios-sim/evidence.zip
```

Since 2026-10-26 each phase also reports the whole app's CPU
(`processCPUmsPerSecondAvg`, getrusage: the renderer and IO threads too) and
the time between presented frames (`frameIntervalP50ms`, `P95`, `Max`).

## #10 Typing brings the prompt back

`TerminalFollowPolicy` holds the following rules, and has unit tests:

- **Input follows.** Any input on the primary screen means "follow" again and
  jumps to the prompt. Input here is what the person typed, pressed or pasted,
  from the keyboard, the key bar or the composer. All of these go through the
  surface's `perform`, which calls `onUserInput`. Ghostty's own replies to
  terminal queries also reach `onInput`, but they never pass through
  `perform`, so a program that queries the terminal does not move a reader.
- **Output does not move a reader.** Output never moves someone who scrolled
  up. Output while at the bottom stays pinned.
- **Lost rows follow.** In two cases the screen follows again:
  - the scrollback was cleared (`clear`, `ESC [3J`), which leaves at most one
    screen of rows;
  - the document ends above the place on screen, which would leave only blank
    rows there.

  Ghostty trimming old pages at the scrollback limit, or a reflow, also lowers
  the total row count. Neither moves a reader.

## #7 Files and Links preview

**Cause.** The Mac refuses a `file` read by closing the channel with a code:
`forbidden`, `not_found` or `bad_request`. The FFI channel dropped that code,
so a refused read looked like an empty file and the preview stayed blank.

**Phone change.**

- The file source reads the peer's close code from `LinkChannel.closedBy`. That property came with the latest `feat-cnx-ios`; this branch first added its own `closeError()` and dropped it in the merge.
- The file source turns a refusal into a truthful message, shown with a
  **Try Again** button:
  - outside the shared folders: "x.md is outside the folders <Mac> shares
    with this phone";
  - no shared folder at all (hostd's "no workspace roots are shared"):
    "<Mac> isn't sharing any folders with this phone yet, so x.md can't be
    opened here".
- An empty file says "Empty file".
- The preview is never a blank page.

**Mac side (not changed here; it belongs to the machost PR).**

- cmux-mobile-host serves `file` only inside `CMUX_MOBILE_FILE_ROOTS`.
- The Mac app fills that list only from the agent chat roots
  (`AppServices+IPhone.swift`, `fileRoots`: `chats.roots + chats.managedRoots`).
- With no chat roots, which is the default, every read is refused. This is
  also row "File roots" in `production-audit.md`.
- `upload` already accepts the folder of any tab the daemon lists
  (`daemon_folders`, `services.rs`). `file` could confine reads the same way:
  inside a root, or inside the canonical cwd of a live tab. Alternatively the
  Mac app could pass the workspace folders.
- Either is a security-policy decision for the Mac owner; this change does not
  loosen it.

**Accessibility of the list.** In the live runs the sheet, its title, chips
and rows are all in the accessibility tree.

## #12 Key bar accessibility

An accessibility activation lands on the center of the element's frame.
Each key in the middle row reports whether its center is inside the scroll
view's visible bounds (`KeyBarClipping`).

- A key whose center is outside those bounds is hidden from accessibility.
  This covers keys under esc / ctrl / alt and keys under the joystick.
- A key cut at an edge, but with its center showing, stays. A tap at its
  center hits that key.

The hidden keys are offered as accessibility actions on the row ("More keys"),
so VoiceOver can still reach every key.

A first version also hid keys that were only partly visible. That left about
two keys reachable at a time, and the rig's `term_keys` step could not find
`Control C` while scrolling.

## Live runs (E2E rig)

The rig is `verify/e2e`, plus termfix steps (`journey-termfix.py` in the
evidence folder). It ran in one headless simulator, `cmux-mobile-termfix`. The Mac was
a real tagged cmux-next app, running hidden and isolated with its own settings
file and the dev sign-in.

The final run used the current rig Mac, `cmux-mobile-e2e-604fc689`, after the merge
of `origin/feat-cnx-ios` (`0d51855c`). Its evidence is in
`verify/evidence/2026-10-14/termfix/e2e/cmux-mobile-termfix-e2e-604/`, which is
git-ignored.

| Step | Result on `cmux-mobile-e2e-604fc689` |
| --- | --- |
| `tf_type_reveals` (#10) | Pass. For both cases below, the "Scroll to bottom" button was shown before typing; the typed marker showed and the button was gone after. Cases: `seq 1 400`, then scrolled up and typed; `seq 1 400; clear`, then scrolled up and typed. |
| `tf_type_after_files` (#10, the coordinator's sequence) | Pass. After the rig's Files and Links step the page was scrolled up and the jump button was shown. Typing brought the prompt back and the button was gone. |
| `tf_files` (#7) | Pass. The sheet and its rows are in the accessibility tree. This Mac shares no folder (no chat roots), so each preview shows "… isn't sharing any folders with this phone yet …" and a Try Again button, not a blank page. |
| `tf_flood` (#5) | Pass. 20 s of 10 Mbit/s output (`perl`, 999 columns, the input-lane flood). The app's CPU was 57 to 64%. Accessibility reads took 0.32 to 0.34 s. The tap that brings up the keyboard took 1.95 s. Typing 6 keys through axe took 7.1 s. The app was idle, under 15% CPU, 0.6 s after the Mac had the typed text. The matrix's earlier run had touches time out after 120 s. |
| `keystroke_echo_flood` (the rig's latency step, top row 100 times a second) | Median 15 ms, p95 17 ms, max 38 ms, 12 of 12. Earlier, no number could be taken. |
| `keystroke_echo_idle` | Median 0 ms, p95 15 ms, max 18 ms. |
| `tf_keybar` (#12) | Pass. At 3 scroll positions, no key had its activation point under esc / ctrl / alt. |
| `term_direct`, `term_composer`, `term_scrollback` | Pass. |

An earlier run used the older rig Mac `cmux-mobile-e2e-210e55d9`, with a chat root
set in its own settings file. That run showed the positive case:

- a file in the shared folder previewed its text ("hello from inside");
- a file in `/tmp` showed "… is outside the folders … shares with this
  phone".

**The rig's `term_keys` step needs a change.** The rig's `reveal_h` finds a
key by its frame, even when the key is off screen. Keys whose center is off
screen are no longer in the accessibility tree, so the step fails. The rig
must scroll the row when a key is missing. `_keybar_seek` in
`journey-termfix.py` is a start: with it, `Control C` was found and used.

## Tests

- `swift build --build-tests` and `swift test` on `mini-cmuxs-mac-mini-2`
  (Xcode 26.3): 280 tests in 88 suites pass after the merge. New tests:
  - `TerminalOutputQueueTests`
  - `TerminalFollowPolicyTests`
  - `KeyBarClippingTests`
  - `TerminalArtifactCollectorTests`
  - `DaemonTerminalEventParserTests`
  - `DaemonTerminalInboxTests`: one main hop for 1000 lines, and the reader
    waits while paused or behind.
  - `LinkFileRefusalTests`
- The existing `DaemonTerminalSessionTests` pass unchanged.
- The iOS simulator Debug, Demo and Production builds compile.
