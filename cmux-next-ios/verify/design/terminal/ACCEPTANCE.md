# Terminal acceptance: criteria, load matrix and evidence plan

Author: acceptance author (separate from the implementer and from every
verifier, per `skills/debug/verify-implementation`). Written 2026-10-14 against
`origin/feat-cnx-ios-termqa` d9e28efa.

This document is the gate for the cmux-next iOS terminal (`CmuxMobileKit/Sources/CmuxMobileTerminal`,
`CmuxMobileLive/DaemonTerminalSession.swift`) and the paths next to it: the tab grid,
the Feed's terminal deep link, reconnect and transports. The implementer does not
edit this file. A verifier who thinks a threshold is wrong reports it. Only the
acceptance author changes a threshold, in a commit that gives the reason.

The user's words set the bar: "The terminal experience on iOS is giving me a lot
of difficulties, even more so with an agent like Codex in an extended session",
"make sure that the terminal experience, especially with agents, is extensively
verified and perfected", "stringent and cover all capabilities under extreme
loads of pressure", "don't use direct paths or local socket paths in your
verification".

Read with: `verify/terminal-scroll-model.md` (the scroll states this document
tests), `verify/design/terminal/SPEC.md` (B/M/P items), `qa-round-1.md`
(D1-D6, U1-U2), `REVIEW-round4.md` (R3-x, R4-x), `UPSTREAM-REQUESTS.md` (U1-U7),
`PROTOCOL.md` (link, lanes, transports).

---

## 0. How to read a criterion

Each criterion has a stable ID (`T-AREA-NN`). A row gives:

- **Criterion**: what must be true.
- **Threshold**: a number. "0" means zero tolerance. A row with no number is a defect in this document.
- **Measure**: the method from section 2 (`M-…`).
- **Scenario**: an existing rig step (`journey.py` / `tq.py` name), or a scenario defined here (`S-…`). A name marked † does not exist yet and is listed in section 11 (Gaps).
- **Artifact**: what the verifier must find in the evidence folder (`mp4`, `frames`, `json`, `log`, `png`, `txt`).

The fixed terms:

- **Row**: one terminal cell row on the phone, in points (pt). At the default font on an iPhone 17 Pro (402 × 874 pt, 3 px/pt) a row is about 15 pt (45 px). The analyzer finds the row height from the recording (section 2, M-MOTION) and reports shifts in px and in rows.
- **Zero drift**: a vertical shift of the read rows of at most 1 px (scaling noise) between consecutive frames.
- **Foreign frame**: a frame whose terminal band shows rows that are not contiguous with the rows of the frame before and the frame after it, or a frame unlike both neighbours while the neighbours are alike (motion.py's "flash").
- **Black frame**: a frame whose terminal band (below the status bar, above the composer) has fewer than 0.4 % of pixels lit (luma > 60) while the expected content has text.
- **Hitch**: a presented frame whose interval exceeds the display's frame budget by more than one budget (> 33.4 ms at 60 Hz, > 16.7 ms at 120 Hz).
- **Hang**: main thread blocked for more than 250 ms. **Stall**: more than 100 ms.
- **Replay**: a mirror reset followed by a full screen and scrollback replay from the Mac (`terminal-sizing` log line `mirror reset …`).
- **Spurious resize**: a `resize-surface` the phone sends that is not caused by one of the allowed triggers in T-SIZE-01.
- **Following / reading / interacting**: the states in `terminal-scroll-model.md`.

Percentiles are over at least 50 samples unless the row says otherwise. A run
whose laptop 1-minute load average exceeds 12 at any point in the measured
window is **invalid for timing rows** (state, order, content and zero-count
rows still count). This avoids round 1's problem, where load 24-90 made every
timing meaningless. Timing rows are rerun until a valid window exists. They
are never waived.

---

## 1. Evidence rules (apply to every criterion)

### 1.1 Path under test

1. **Real link only.** Phone app → real link (WebRTC or WireGuard, through the
   real signaling Worker and, when the path needs it, TURN or the Worker relay) →
   `cmux-mobile-host` → the cmux-tui daemon → a real PTY. None of these counts for a
   pass: the daemon socket, a loopback link, `MockTerminalSession`,
   `FakeCodexSession`, `PendingTerminalSession` demo output, `TerminalFloodBench`'s
   fake daemon, Demo-mode output, or any DEBUG direct-to-daemon path. Unit tests
   are useful for the implementer. They are not acceptance evidence.
2. **No local or direct shortcuts for the stimulus.** The user said: "don't use
   direct paths or local socket paths in your verification". Every command,
   keystroke, paste and agent prompt in a scenario is entered **on the phone**
   (composer paste + Send, soft keyboard, key bar, hardware keyboard). The Mac's
   bundled CLI (`cmux terminal write`, `journey.mac_write`) and any Mac-side
   socket are **forbidden as stimulus**. Today the rig uses `mac_write` in
   `scroll_while_streaming`, `tui_quit_keyboard_up`, `reattach_no_jumps` and
   others. Those steps must be ported (section 11, G-01) before their results
   count. Mac-side access is allowed only for:
   - (a) read-only oracle reads: the Mac's screen text, daemon and `cmux-mobile-host`
     logs, the agent's PID;
   - (b) fault injection: kill `cmux-mobile-host`, netsim, quit the Mac app;
   - (c) staging fixture files (the load generators and the test project) over
     ssh before the run.

   Each use is written in the manifest.
3. **Two machines.** The Mac side is the real tagged cmux-next app with the
   bundled `cmux-mobile-host`, daemon and acpmux, built by the fleet from the pushed SHA
   under test. It is launched hidden with an isolated config (`termqa/rmac.py`).
   It runs on a **cmux Mac mini from `~/.ssh/mini-hosts.json`**, not on the
   laptop that runs the simulator. Round 1 used `mini-cmuxs-mac-mini-2`. A
   same-machine run (`e2e/run.sh` today) is allowed only for smoke checks and
   never satisfies a criterion.
4. **Both transports.** Every criterion in sections 3-9 passes on **WebRTC** and
   on **WireGuard**. Path labels used below:

| Label | Transport | Path | How it is forced |
| --- | --- | --- | --- |
| `W-D` | WebRTC | direct (host/srflx) over LAN | default |
| `W-T` | WebRTC | TURN relay | Settings → Developer → Relay only (gathers only relay candidates) |
| `G-D` | WireGuard | direct UDP | Settings → Connection → Transport: WireGuard |
| `G-T` | WireGuard | via TURN | WireGuard + Relay only, with TURN listed by `/v1/ice` |
| `G-R` | WireGuard | Worker WSS relay frames | WireGuard + Relay only + TURN suppressed† (G-06) |

   Full sections 3-9: `W-D` and `G-D`. Load matrix (section 10): every load on
   `W-D` and `G-D`. The marked subset also runs on `W-T`, `G-T`, `G-R` and the
   netsim profiles. The manifest records the path that the link reported
   (`link` log `path=`), not the path that was asked for. A run that asked for
   `G-T` and got `direct` is invalid.

### 1.2 Platform

- Simulator: iPhone 17 Pro, iOS 26.5 and iOS 27.0, headless, one simulator per
  agent (deleted after), Production-equivalent **Demo** config with DEBUG probes
  compiled in. Probes must be compiled out of Production
  (`check-production-binary.sh --shipping`).
- Dark and light. Default text size, plus the largest accessibility size for
  T-REND, T-SIZE and T-TABS.
- Device-only criteria (section 12) are never passed from a simulator.

### 1.3 Evidence manifest (one per SHA per round)

Path: `cmux-next-ios/verify/evidence/<date>/termaccept/<round>-<sha10>/manifest.json`.
Large videos stay in `~/cmux-next-ios-e2e/termaccept-raw/<round>-<sha10>/`. The
manifest carries each one's sha256 and duration, so a verifier can confirm it is
the file analysed. Shape:

```json
{
  "round": "R3", "ios_sha": "…40", "mac_sha": "…40", "mac_tag": "cmux-mobile-e2e-…",
  "ios_build": "Demo …", "simulator": {"runtime": "iOS-26-5", "udid": "…"},
  "mac_host": "mini-cmux…", "laptop_load_max": 7.9,
  "verifier": {"session": "…", "fresh": true, "prior_rounds_seen": false},
  "mac_side_uses": [{"t": "…", "kind": "oracle|fault|stage", "what": "…"}],
  "results": [{
    "id": "T-SCROLL-04", "path": "W-D", "status": "pass|fail|blocked|invalid",
    "measured": {"drift_px_max": 0, "foreign_frames": 0, "frames": 3612, "fps_effective": 59.2},
    "artifacts": [{"file": "…mp4", "sha256": "…", "kind": "mp4"},
                  {"file": "…motion.json", "kind": "json"}],
    "scenario": "S-READ-STREAM", "notes": "…"
  }]
}
```

Rules:

- Each row's `measured` holds the raw numbers its threshold is checked against.
  Words such as "smooth", "looks fine" or "no issue seen" fail the row.
- A run that is invalid (load gate, wrong path, recording below 30 effective
  fps in the window) records `invalid`. It is neither `pass` nor `fail`.
- The manifest is committed with the analysis outputs (json, contact sheets).
  It is not edited after the verifier signs it. A rerun gets a new round ID.

### 1.4 Recording

- Simulator: `simctl io recordVideo` (H.264, variable frame rate up to 60 fps).
  Every analysis resamples to 60 fps. The window under test needs **≥ 30
  effective fps**: fewer than 2 % of source frame gaps may exceed 34 ms. If
  not, the row is `invalid`.
- Device (section 12): the iOS screen recording (60 fps, 1320 × 2868 on the
  user's phone), plus an Instruments trace for hitches.
- Every gesture the rig makes is logged with host time and mapped into video
  time (M-TOUCH). Analysis then separates motion caused by the finger from
  motion the app made on its own. Today only `latency.py` maps times.

### 1.5 Verifiers

- **A fresh adversarial verifier each round.** It is a new session that did not
  implement anything and did not verify a prior round. It gets only: this
  document, the SHA, the manifest and the raw artifacts. It reruns the
  analyzers itself on the raw videos and logs. It does not copy the
  implementer's numbers. It must also try to break the build outside the
  scripted scenarios for at least 20 minutes (free play on S-AGENT-CODEX, rows
  T-ADV-01, T-ADV-02).
- A verifier states one verdict per criterion: pass, fail, invalid or blocked
  (needs device / needs tool). A blocked row is not a pass.

---

## 2. Measures

| ID | Measure | What it gives | Exists? |
| --- | --- | --- | --- |
| M-MOTION | `verify/termqa/motion.py`: per frame, the vertical shift of the terminal band against the previous frame, direction reversals within 0.5 s, and flashes. Needs: row-height calibration (px → rows), M-TOUCH overlay to label each move as finger-driven or spontaneous, json output. | drift px, jumps, oscillation, flashes | partial (G-02) |
| M-BLACK | Lit-pixel test of the terminal band per frame (threshold in section 0). The same test is inline in `journey.s_scroll_while_streaming`, and a standalone version is needed. | black frames | partial (G-02) |
| M-ROWS | Row-identity tracker: load generators print a numbered row id (`#000123`) in a fixed column. OCR (`e2e/ocr.swift`) reads the visible ids per frame at 10-60 fps. Gives the exact visible window, contiguity (foreign frames), drift in rows, and the top and bottom row ids. | foreign frames, read-row drift, bottom-row visibility, history reach | no (G-03) |
| M-FRAMELOG | In-app (DEBUG/Demo) `OSSignposter` intervals on the `terminal` subsystem: `output-batch` (bytes, ms), `apply-scroll` (state, offset), `draw` (Ghostty frame), plus a CADisplayLink interval log (target vs actual timestamp), streamed with `log stream --style ndjson`. | frame intervals, hitches (where the simulator allows), main-thread work per frame | no (G-04). Today only the DEBUG scroll meter and the `terminal-sizing` log. |
| M-HANG | In-app main-thread watchdog (a background thread pings the main run loop every 50 ms and logs any block over 100 ms with a backtrace), plus `journey.check_hang` (process sample when AX does not answer). | stalls, hangs | partial (G-05) |
| M-SIZELOG | `terminal-sizing` log: each `resize-surface` sent (cause, cols × rows), each mirror reset (cause), each replay (bytes, ms). | spurious resizes, replay count | exists (needs a `cause` field on every line: G-07) |
| M-ECHO | Keystroke → echo latency over the real link. **Primary:** an in-app probe that stamps the touch-down of a key (key bar, soft keyboard or hardware keyboard), sends a unique byte sequence, and stamps the first presented frame after Ghostty processed bytes that contain its echo. It extends `TerminalBenchProbe`, which today works only against the fake daemon. **Cross-check:** `e2e/latency.py` (video: key highlight → cursor-line change, ±1 frame). | p50/p95/p99 echo | partial (G-08) |
| M-INTEG | Integrity: a generator writes N numbered lines with a per-line CRC32 and a final total. A DEBUG-only phone export (the terminal's full text via `TerminalSurfaceView` read-text, written to the app's log or a file read with `simctl`) is checked: every id once, in order, CRC correct, plus the Mac screen's tail. | lost, duplicated, reordered, garbled rows | no (G-09) |
| M-MAC | Mac oracle (read-only): the Mac's screen text for the same terminal, daemon/`cmux-mobile-host`/acpmux logs, the agent process PID and start time (ssh to the mini). | phone vs Mac agreement, agent survives | exists (`tq.mac_screen`, `rmac.py`) |
| M-MEM | `footprint -p` / `ps` on the simulator app every 5 s (`tq.app_mem`), CPU % every 5 s, the Mac's `cmux-mobile-host` and daemon RSS/CPU every 30 s. Output: a time series json plus a slope. | memory ceiling, growth, CPU | partial (G-10: series + slope) |
| M-LINK | `link` log: path, RTT, reconnects, keepalive, channel overflow closes. `cmux-mobile-host` log: link up/down, refusals. | path proof, drops, overflow | exists |
| M-TOUCH | The rig logs every synthetic touch, key and gesture with host time, mapped into video time with the recording's start offset. | finger-driven vs spontaneous motion | partial (G-02) |
| M-AX | Accessibility snapshot (`axe`) of the page: control frames, labels, hidden controls. | overlap, hit areas, hidden controls | exists |
| M-NETSIM | Injected latency, jitter, loss and bandwidth on the Mac side (G-11). | slow-link rows | **no** |
| M-LOADGEN | Fixture scripts staged on the Mac and started from the phone (section 10.1), plus a multi-tab launcher that opens N tabs and starts a generator in each from the phone. | load matrix | no (G-12) |

Analyzer outputs are json with the numbers the thresholds name. Every
`frames`/contact-sheet artifact gives the time range and the fps it was cut at.

---

## 3. Rendering correctness (T-REND)

Scenario S-REND: from the phone, run the fixture `render-suite` (section 10.1):
the 16 base colors, 256 colors and truecolor gradients, bold, italic, underline
styles, inverse, dim, strikethrough; CJK, fullwidth, combining marks, ZWJ emoji,
flags, skin tones, wide characters at the last column (wrap); box drawing and
Powerline glyphs; long wrapped lines; tabs; and cursor shapes (block, bar,
underline, blinking, hidden). Then each TUI in S-TUI. The oracle is the Mac's
screen text (M-MAC) and a reference screenshot of the same terminal in the Mac
app at the same cols × rows.

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-REND-01 | Cell text matches the Mac, cell for cell, for the visible screen after each fixture section | 0 differing cells (excluding the cursor cell) | M-MAC text diff vs the phone's export (M-INTEG export) | S-REND† | txt diff, png |
| T-REND-02 | Colors: 16, 256 and truecolor swatches match the reference colors | ΔE2000 ≤ 3 per swatch, 0 swapped indices | pixel sample at swatch centers vs the expected sRGB | S-REND† | png, json |
| T-REND-03 | Attributes (bold, italic, underline styles, inverse, dim, strike) render | 0 missing attributes in a 1:1 check of the fixture | visual check against a reference image, by the verifier | S-REND† | png pair |
| T-REND-04 | Wide and emoji characters take 2 cells, never overlap the next cell, and wrap correctly at the last column | 0 overlaps, 0 half-glyphs; the column of every later character matches the Mac | M-MAC + crop | S-REND† | png crops |
| T-REND-05 | Cursor at the Mac's cursor position, with the right shape, and blinking only when asked | position exact; 0 stray cursor blocks (the R3-4 saved-frame cursor counts) | M-MAC cursor vs pixel | S-REND†, relaunch | png |
| T-REND-06 | Alternate screen: entering it shows only the TUI, with no scrollback above; leaving it restores the shell screen and scrollback exactly | 0 lost scrollback rows (M-ROWS ids before = after); 0 black frames longer than 1 frame on entry and exit | M-ROWS, M-BLACK | S-TUI | mp4, json |
| T-REND-07 | Full-screen TUIs render whole screens that match the Mac: **Codex, Claude Code, vim, top, less, htop** (each; htop installed on the mini) | per TUI: 0 differing cells against the Mac at 3 checkpoints (start, after interaction, after a resize) | M-MAC | S-TUI (extends `term_tui`) | txt diffs, png ×18 |
| T-REND-08 | No black frame over a TUI during keyboard show/hide (R3-2) | 0 black frames in 4 hides and 4 shows over `top`, and the same over Codex | M-BLACK | `tui_quit_keyboard_up`, S-KB-TUI† | mp4, json |
| T-REND-09 | No blank rows above the Mac's screen (B1) on a short session | 0 blank rows above row 0 at rest; overscroll above row 0 ≤ the rubber-band distance | M-ROWS + M-AX | `term_scrollback`, `composer_bottom_pin` | png |
| T-REND-10 | Text is never under the chrome at rest: the last row ends above the composer, row 0 sits below the toolbar | overlap of the text band with the composer or key bar frame: 0 pt at rest (following) | M-AX frames vs M-ROWS | `composer_bottom_pin` | png, json |
| T-REND-11 | Light and dark, default and AX5 text size: T-REND-01, 04 and 10 hold | as above | as above | S-REND† ×4 appearances | png |

---

## 4. Scrolling (T-FOLLOW, T-SCROLL)

Scenarios:

- **S-FOLLOW**: the `stream20` generator (20 lines/s with a status line redrawn
  below, like Codex's live area) and real Codex.
- **S-READ-STREAM**: the reader scrolls up during `stream20`, then `stream1m`
  (1 Mbit/s colored), then real Codex.
- **S-FLING**: on a 10,000-row history.

Each runs with the keyboard down and with the keyboard up.

### 4.1 Following at the bottom

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-FOLLOW-01 | While following, the newest row is always fully visible above the composer (keyboard down) or above the key bar (keyboard up) | 0 frames (60 fps) where the last non-blank Mac row is hidden or clipped for more than 2 consecutive frames; the last-row bottom edge is ≥ 0 pt above the composer card's top | M-ROWS + M-AX | `composer_bottom_pin`, `tab_switch_last_row`, S-FOLLOW | mp4, json |
| T-FOLLOW-02 | Following moves the page only forward (content goes up). The user's 13:37 video oscillation and D2's 7-row jump stay fixed | 0 spontaneous downward moves greater than 1 row; 0 reversals within 0.5 s; with Codex, a 1-row downward move is allowed only when the Mac's own live area shrank by that row (M-MAC diff proves it) | M-MOTION + M-TOUCH + M-MAC | S-FOLLOW (5 min stream20, 10 min real Codex) | mp4, motion.json |
| T-FOLLOW-03 | Following moves the page in the same frame as the new rows appear: no one-frame jump of 1-2 rows (ae6354ff fix) | 0 frames where the text band shifts by ≥ 1 row and the next frame shifts back | M-MOTION | S-FOLLOW | motion.json |
| T-FOLLOW-04 | No black or foreign frame while following, whether Codex is working or idle (user video 12:59 at 3.30-3.77 s and 26.9-27.3 s) | 0 black, 0 foreign frames over 10 min | M-BLACK, M-MOTION flash, M-ROWS | S-FOLLOW, S-AGENT-CODEX | mp4, json |
| T-FOLLOW-05 | Jump to bottom is shown if and only if the page is not following | 0 frames with the button visible while M-ROWS shows the bottom row (beyond a 300 ms fade); 0 frames without it while reading for more than 300 ms | M-AX poll + M-ROWS | S-READ-STREAM | json |
| T-FOLLOW-06 | Following lag: the phone's newest row is within 250 ms of the Mac's under stream20, and within 1 s under stream1m (LAN) | p95 lag ≤ 250 ms (stream20), ≤ 1 s (stream1m); max ≤ 2× p95 | M-ROWS timestamps vs generator timestamps (each line carries its send time) | S-FOLLOW | json |

### 4.2 Reading scrollback while output streams

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-SCROLL-01 | Read rows stay put: after the finger lifts and deceleration ends, the visible row ids and their y positions never change while output streams | **0 px drift** (≤ 1 px) of the read rows for 60 s under stream20, stream1m and real Codex, each; the top visible row id stays constant | M-ROWS, M-MOTION | S-READ-STREAM (extends `codex_scroll_hold`, `scroll_while_streaming`) | mp4, json |
| T-SCROLL-02 | No flash or foreign region while reading or scrolling during a stream (user videos 12:59 at 20.5/23.13 s, 13:37 at 6.83 s and 8-9 s; termqa U1) | **0 foreign frames**, 0 black frames at 60 fps over every S-READ-STREAM recording (≥ 5 min total per path) | M-ROWS contiguity + M-MOTION flash + M-BLACK | S-READ-STREAM, `scroll_to_bottom_stable` | mp4, json |
| T-SCROLL-03 | No oscillation: a page at rest (no finger) never moves | 0 spontaneous moves while reading; 0 reversals within 0.5 s at any time without a finger | M-MOTION + M-TOUCH | S-READ-STREAM, S-FOLLOW | motion.json |
| T-SCROLL-04 | No resume-following by surprise: reading stays reading while output appends, a TUI redraws, or the end moves up (F2) | 0 transitions reading → following without a user action (scroll-model log) | M-FRAMELOG `apply-scroll` state | S-READ-STREAM | log |
| T-SCROLL-05 | The scroll follows the finger: during a drag, content moves with the finger | Content displacement vs finger displacement: error ≤ 2 pt per frame; 0 frames where content moves against the finger | M-MOTION + M-TOUCH | S-FLING† | json |
| T-SCROLL-06 | Fling and deceleration: no hitch in steady fling, and the deceleration is monotonic | 0 reversals during deceleration; main-thread work per frame p99 ≤ 4 ms, max ≤ 12 ms (sim); device hitches in section 12 | M-FRAMELOG, M-MOTION | S-FLING† (extends `v2-fling`) | log, json |
| T-SCROLL-07 | Rubber-band at the top and bottom edges returns to rest with no jump | Return in ≤ 600 ms; final offset exactly at the edge (0 px); 0 overshoot past the edge after release | M-MOTION | S-FLING† | json |
| T-SCROLL-08 | A fling into a streaming bottom ends following (scroll model) | 100 % of 10 flings toward the bottom end following within 1 s of reaching it; 0 frames of blank rows below the last row | M-ROWS + M-AX (Jump button gone) | `scroll_while_streaming` | json |
| T-SCROLL-09 | Jump to bottom returns to the live bottom in one motion | Reach the bottom ≤ 400 ms after the tap; the first frame after the tap is either the start of the animation or the bottom; 0 foreign frames; then following | M-ROWS, M-AX | S-READ-STREAM | mp4 |
| T-SCROLL-10 | Scroll to the very top of history: the phone reaches the Mac's first history row | Row id #000001 visible (10,000-line history); time from the first fling ≤ 10 s of repeated flings; 0 blank region at the top (user video 12:59 at 48.7-50.6 s: 1.9 s black with a cursor block) | M-ROWS, M-BLACK | `scrollback_history`, `shell_pull_keyboard_up`, S-FLING† | mp4, png |
| T-SCROLL-11 | No blank document region anywhere: every offset the page can reach shows rows that exist | 0 frames with ≥ 3 consecutive blank rows inside the content where the Mac has text (checked over a full top-to-bottom sweep) | M-ROWS + M-MAC | S-SWEEP† | json |
| T-SCROLL-12 | TUI mode pinning and scrolling: in an alternate-screen TUI (vim, top, less, htop, Codex, Claude Code) the page is pinned and never scrolls the phone's scrollback. A vertical drag scrolls the TUI the way a Mac trackpad does in Ghostty, through Ghostty's own scroll path (`ghostty_surface_mouse_scroll`, precise deltas in the natural direction, 1:1 with a finger slower than 300 pt/s so a slow drag moves line by line, rising to 3x at 3000 pt/s like a Mac trackpad's acceleration, and momentum after a fling that carries the same gain and decays 0.95 per 1/60 s; one main-queue turn's wheel reports are one `send`, and input never waits for the last `send`'s reply): a TUI that enabled mouse reporting (DECSET 1000/1002/1003 with 1006) gets wheel reports (buttons 64 up / 65 down) at the touched cell; otherwise, with alternate scroll on (DECSET 1007, on by default), cursor up/down (`ESC [ A`/`B`, `ESC O A`/`B` in application cursor mode); with 1007 off, nothing. The wheel stays at the cell where the drag began. A tap in a TUI that enabled mouse reporting is also a left click at that cell (press and release, in the app's mouse encoding), and it still focuses the terminal. A one-finger drag is always the wheel (the trackpad model), so a drag-select inside a mouse-mode app is not offered. A tap still focuses the terminal, a long press still selects (a drag clears the selection), a selection handle still moves, a new touch stops a fling (that tap does nothing else, so it raises no keyboard), and keyboard and composer behavior is unchanged. The TUI's bottom row rests on the composer | 0 px of page scroll from 10 drags; each of 10 drags (5 up, 5 down) moves the TUI's content in the drag's direction in `less` (arrows), `htop` (wheel) and a Claude Code or Codex session with long output; TUI bottom row ≥ 0 pt above the composer; `TerminalTUIScrollSurfaceTests` green (exact bytes for 1000+1006 wheel, 1002 and 1003 wheel, plain and application-cursor arrows, 1007 off, a partial row carried) | M-MOTION, M-MAC (the TUI's state changed) | S-TUI | mp4 |
| T-SCROLL-13 | Leaving a TUI returns to following at the shell prompt, keyboard up or down (R3-1) | prompt visible above the composer ≤ 300 ms after the TUI exits; history reachable by a pull | M-ROWS | `tui_quit_keyboard_up` | mp4 |
| T-SCROLL-14 | Scrolling never resizes the PTY | 0 `resize-surface` during any scroll gesture | M-SIZELOG | `no_resize_on_scroll` | log |
| T-SCROLL-15 | The keyboard drag-dismiss from the prompt keeps the prompt on the composer (M6) | Prompt row stays ≤ 2 pt from the composer top through the whole drag (each frame) | M-ROWS + M-AX | `shell_pull_keyboard_up` | mp4 |
| T-SCROLL-16 | Pull-down with the keyboard up reaches history (R3-1) | 3 pulls reach the session's first row (short session) | M-ROWS | `shell_pull_keyboard_up` | png |
| T-SCROLL-17 | A swipe on the key bar never scrolls the terminal or swipes back (R4-1) | 0 of 20 horizontal swipes (pinned keys and scroller) pop the page; 0 px terminal scroll | M-AX, M-MOTION | `keybar_swipe_no_back` | mp4 |
| T-SCROLL-18 | The scroll indicator's position matches the visible rows | indicator center within 3 % of the visible-row fraction of history | M-AX / pixel | S-SWEEP† | json |

---

## 5. Input (T-INPUT)

Echo latency is measured over the real link (M-ECHO primary; the video
cross-check must agree within 20 ms at p50). Path RTT is the `link` log ping
median over the same window. Simulator LAN paths: `W-D`, `G-D`. Targets tighten
the production ACCEPTANCE.md's 50/80 ms, because round 1 measured 15/32 ms idle.

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-INPUT-01 | Echo latency at idle (shell, LAN) | p50 ≤ 30 ms, p95 ≤ 50 ms, p99 ≤ 80 ms (n ≥ 200) | M-ECHO | `latency keystroke_echo_idle` (+ G-08 probe) | json |
| T-INPUT-02 | Echo latency under flood (`yes`, stream1m, cat50) | p50 ≤ 50 ms, p95 ≤ 100 ms, p99 ≤ 150 ms (n ≥ 200 per load) | M-ECHO | `latency keystroke_echo_flood`, section 10 | json |
| T-INPUT-03 | Echo latency on relay paths (`W-T`, `G-T`, `G-R`) and netsim profiles | p95 ≤ path RTT + 50 ms; p99 ≤ path RTT + 100 ms | M-ECHO + M-LINK | section 10.3 | json |
| T-INPUT-04 | Zero lost, duplicated or reordered keystrokes: 2,000 random printable chars, 200 at 30 chars/s bursts, with and without flood | Mac receives exactly the sent sequence: 0 lost, 0 dup, 0 reordered | `cat > file` on the Mac, then sha256 vs the sent string (M-MAC) | S-TYPE-INTEG† | txt, json |
| T-INPUT-05 | ^C during a flood stops it: ^C reaches the Mac within the T-INPUT-02 ceilings (input lane), and the phone stops showing new flood output | ^C at Mac ≤ 150 ms p95 (from the key-down); the phone's last flood row is shown ≤ 1.5 s after the key on LAN, ≤ 4 s on `G-R` | M-ECHO style stamp + M-ROWS | S-CTRLC-FLOOD† | json |
| T-INPUT-06 | Composer paste then Send submits as one paste followed by Return (F1), multi-line paste uses bracketed paste when the shell asks for it, and there is no auto-Return for attachments | 20 of 20 pastes (1 line, 50 lines, 10 KB) arrive byte-exact; Return arrives after the paste end | M-MAC | `composer_submit` | txt |
| T-INPUT-07 | Special keys: Esc, Tab, ⇧Tab, arrows, Home/End/PgUp/PgDn, F1-F12 (if on the bar), Ctrl-A…Z, Ctrl-[ ] \ ^ _, Alt/Meta combos send the right bytes | 100 % of a 60-key table matches the expected byte sequences on the Mac (`od -c` echo fixture) | M-MAC | `term_keys` extended† | txt |
| T-INPUT-08 | Sticky ctrl applies to the next key typed in the terminal and in the composer, then disarms (M1) | 10 of 10 | M-MAC | `term_keys` | txt |
| T-INPUT-09 | Joystick: a tap sends 1 arrow; a hold repeats at a fixed rate | tap: exactly 1 per tap (20 taps); hold: first repeat 300-500 ms, then 10-20 Hz steady (±15 %); 0 repeats after release | M-MAC (count arrows) + M-TOUCH | `joystick_paste_close` | json |
| T-INPUT-10 | Key bar (shortcuts): ^C is reachable without scrolling (B2); gaps stay even after swipes (R3-5); keys hit their labels | ^C visible at rest; key gap 6 ± 1 pt at rest and after 10 swipes; hit test: 0 of 30 taps land on a neighbour | M-AX | `keybar_swipe_no_back`, `term_keys` | json, png |
| T-INPUT-11 | Hardware keyboard: all of T-INPUT-07 plus ⌘C, ⌘V, ⌘K (if defined), key repeat, and the key bar layout rule (M4) | 100 % of the table; key repeat 0 lost/dup | M-MAC | S-HWKB (simulator hardware keyboard via HID events; device in section 12) | txt |
| T-INPUT-12 | Dictation and IME: a marked-text session (Japanese kana → kanji, Chinese pinyin) commits only the final text; emoji keyboard input arrives as UTF-8 | 0 intermediate marked text on the Mac; final bytes exact | M-MAC | S-IME† (simulator keyboards); dictation is device-only (T-DEV-07) | txt |
| T-INPUT-13 | The composer does not autocorrect, predict, capitalize or AutoFill in the shell (M2) | 0 changes to 20 typed shell words | M-MAC | `term_composer` | txt |
| T-INPUT-14 | Attachments: image, file and camera reach the Mac at the right path; the path is inserted with no Return | 3 of 3 types arrive (sha256 equal); 0 auto-Return | M-MAC | `image_upload` | json |
| T-INPUT-15 | Typing returns to following at once (`revealCursorForInput`) | the prompt is visible ≤ 1 frame after the first echo frame | M-ROWS | S-READ-STREAM + type | mp4 |
| T-INPUT-16 | Input reaches the right tab after tab switches: type into tab A, switch to B, type, back to A | 0 cross-tab keystrokes in 20 switches | M-MAC | S-TABTYPE† | txt |
| T-INPUT-17 | Input while the link reconnects: keystrokes typed during a drop either arrive once after the reconnect, in order, or are refused visibly; never silently lost | 0 silent losses; 0 dups (50 keys typed during 5 drops) | M-MAC | S-DROP-TYPE† | txt |

---

## 6. Selection, copy, links, search (T-SEL)

Today there is no in-terminal text selection (`selectionRects` returns `[]`)
and no search. Files and Links exists. Copying text out of the terminal is a
basic terminal capability, and an agent's output is often copied. These rows
therefore require it. They are `fail` until it exists, not `n/a`. If the user
decides to ship without selection, the acceptance author records the decision
here.

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-SEL-01 | Long-press selects a word; handles extend across rows and into scrollback; Copy puts exact text on the pasteboard (wrapped lines joined only at soft wraps) | 10 of 10 selections exact vs M-MAC text | pasteboard read | S-SEL† | txt |
| T-SEL-02 | Selection holds while output streams (the selected rows do not move or lose selection) | 0 px drift of the selected rows for 30 s under stream20 | M-ROWS | S-SEL† | mp4 |
| T-SEL-03 | Links: URLs and file paths in output are tappable (or listed in Files and Links), and open the right target | 10 of 10 | M-AX | `files_links` | png |
| T-SEL-04 | Files and Links joins rows only at soft wraps; no fragments from TUI full-width rows (R4-2) | 0 fragments, 0 tails (`rivate/…`) | M-AX list | `files_links` | json |
| T-SEL-05 | A refused preview shows a plain refusal with no live-looking controls (M7) | 0 Preview/Source/More controls on a refusal | M-AX | `files_links` | png |
| T-SEL-06 | Search in scrollback (if offered): every match found, Next/Prev jumps exactly to the row | 100 % of 20 planted matches; target row centered ± 1 row | M-ROWS | S-SEARCH† (only if the feature ships) | json |

---

## 7. Sizing (T-SIZE)

Each resize costs a full replay of screen and scrollback, so spurious resizes
are a disruptive defect.

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-SIZE-01 | Only allowed triggers send `resize-surface`: (a) the first attach, (b) a rotation, (c) a keyboard show or hide **only in TUI mode** (`TerminalTUISizing`), (d) a width change (split view or Stage Manager, iPad only), (e) a text-size change | **0 spurious resizes** over the whole round: none from scrolling, composer growth, a transient composer height, the key bar, tab switch, grid zoom, background/foreground with the same geometry, reconnect with the same geometry | M-SIZELOG (each line's cause) | all scenarios | log summary json |
| T-SIZE-02 | At most one replay per attach, and one per allowed resize (D4: the Mac answering the attach with 39 rows, then a `resized` event, gives two today) | replays per attach = 1 (100 % of 30 attaches); replays per allowed resize ≤ 1 | M-SIZELOG | `reattach_no_jumps`, S-LIFE-* | log |
| T-SIZE-03 | The attach carries the final size, and the Mac's first screen is already at that size | cols × rows of the Mac's first `attached` = the phone's request in 30 of 30 | M-SIZELOG + M-MAC | S-LIFE-COLD† | log |
| T-SIZE-04 | Rotation portrait → landscape → portrait: one resize each, no black frame, reading position kept (the anchored row stays the top row ± 1) or following kept | 1 resize per rotation; 0 black frames; anchor ± 1 row | M-SIZELOG, M-BLACK, M-ROWS | S-ROTATE† | mp4, log |
| T-SIZE-05 | Keyboard show/hide in the shell: no resize; the last row stays on the composer; content moves monotonically with the keyboard, with no final snap (D1: 276 px down, then 31 px up) | 0 resizes; 0 reversals; final settle ≤ 1 px from target; 10 hides and 10 shows per run | M-SIZELOG, M-MOTION | S-KB† (extends `r1-s3`) | mp4, json |
| T-SIZE-06 | Keyboard show/hide in a TUI: one resize per change, a held frame while the TUI redraws, 0 black frames (R3-2), 0 old frames left after 1.2 s | 1 resize; 0 black; TUI repainted at the new size ≤ 1.2 s (macOS top repaints every 1 s) | M-SIZELOG, M-BLACK, M-MAC | S-KB-TUI† | mp4 |
| T-SIZE-07 | Composer growth (1 → 6 lines and back) moves the terminal bottom with the composer and sends no resize | 0 resizes; last row ≥ 0 pt above the composer each frame | M-SIZELOG, M-AX | `composer_bottom_pin` | mp4 |
| T-SIZE-08 | Columns fit the width with the M5 inset; no column cut at either edge | first and last columns fully visible; leading inset ≥ 4 pt | pixel | S-REND† | png |
| T-SIZE-09 | Largest text size and pinch zoom (if offered): one resize, correct reflow | 1 resize; T-REND-01 holds after | M-SIZELOG, M-MAC | S-REND† AX5 | png |

---

## 8. Lifecycle (T-LIFE)

All timings run on a valid load window, n ≥ 20 per row per path. A **first
correct frame** is the first frame that equals the settled screen (M-ROWS ids
and positions equal; `latency.settle_time`).

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-LIFE-01 | Cold open of a terminal tab (link up, tab never opened): time from tap to first correct frame | p50 ≤ 800 ms, p95 ≤ 1.2 s | M-VID settle + M-TOUCH | S-LIFE-COLD† | json, mp4 |
| T-LIFE-02 | Cold open shows no blank frame, no wrong-size frame and no frame with fewer rows than the final one (R3-4's "one frame lacking the last rows") | 0 blank, 0 wrong-size (cols ≠ final), 0 partial frames; a dimmed held frame or skeleton is allowed before the first correct frame | M-BLACK, M-ROWS | S-LIFE-COLD† | json |
| T-LIFE-03 | Warm switch between two open terminal tabs (grid → card) | p50 ≤ 100 ms, p95 ≤ 150 ms to the first correct frame (round 1: 1.17/1.28 s, a miss) | `latency tab_switch` | `latency tab_switch` | json |
| T-LIFE-04 | Background 10 s → foreground: the last frame shows at once, input works, no replay when the link survived | first frame = the pre-background frame; input echo ≤ T-INPUT-01; 0 replays | M-VID, M-SIZELOG | S-BG10† | mp4, log |
| T-LIFE-05 | Background 10 min → foreground: held frame at once, live ≤ 1.5 s p95, output produced while away is all present | live p95 ≤ 1.5 s; M-INTEG 0 lost rows from a generator run while away; 1 replay at most | M-VID, M-INTEG, M-SIZELOG | S-BG600† (extends `background`) | json |
| T-LIFE-06 | App relaunch (terminate + launch): the last tab restored with its saved frame, then live; saved frame with no cursor block (R3-4) | saved frame within the app's first frame; live p95 ≤ 2.5 s; one-frame handoff (no blend, no partial rows) | M-VID | `relaunch_restore` | mp4 |
| T-LIFE-07 | Phone lock / unlock (simulator: `simctl` lock if available, else device-only) | as T-LIFE-04 (≤ 30 s locked), as T-LIFE-05 (10 min locked) | as above | S-LOCK† / T-DEV-05 | mp4 |
| T-LIFE-08 | Link drop mid-stream (kill -9 `cmux-mobile-host` on the Mac; the supervisor restarts it): no blank screen, no `[unknown surface N]` or other error text (D3) | 0 blank frames; 0 error text frames; the held frame stays until the replay | M-BLACK, OCR | S-DROP (`r2-s5`) | mp4 |
| T-LIFE-09 | After the drop, resume at the right place: following resumes at the live bottom; reading resumes at the same anchored row | following: bottom ≤ 1 s after link up; reading: same top row id ± 0 | M-ROWS | S-DROP, S-DROP-READ† | json |
| T-LIFE-10 | After the drop, no duplicate, garbled or lost screen content | M-INTEG: 0 lost, 0 dup, 0 garbled over 10 drops during stream20; phone tail = Mac tail (M-MAC) | M-INTEG, M-MAC | S-DROP | json |
| T-LIFE-11 | The agent keeps running on the Mac through every drop | Codex/Claude PID and start time unchanged; agent output continued during the drop (Mac log) | M-MAC | S-DROP-AGENT† | json |
| T-LIFE-12 | Reconnect time after the Mac side is back | link up ≤ 1.5 s p95 after `cmux-mobile-host` is listening; screen live ≤ 2.5 s p95 | M-LINK, M-VID | S-DROP, `mac_restart` | json |
| T-LIFE-13 | Mac app quit and relaunch: the tab shows offline (truthful), then reattaches by itself | offline label ≤ 5 s; reattach ≤ 3 s after the Mac app is up; 0 stuck "Connecting…" (> 10 s with the Mac online) | M-VID, M-LINK | `mac_restart` | mp4 |
| T-LIFE-14 | Network switch with WireGuard roaming (`simulate_network_loss` + roam, `roam_probe`): the terminal does not reset | stall ≤ 2 s p95; 0 replays; 0 lost rows (M-INTEG) | roam_probe + M-SIZELOG + M-INTEG | `roam_probe` + S-ROAM-TERM† | json |
| T-LIFE-15 | Relay-only path: every T-LIFE row holds on `W-T`, `G-T` and `G-R`, with timings + path RTT | as each row, + RTT | M-LINK | section 10.3 | json |
| T-LIFE-16 | Transport switch WebRTC ↔ WireGuard with a terminal open: one reattach, screen intact | 1 replay; 0 blank frames; M-INTEG 0 lost | M-SIZELOG, M-BLACK | `transport` extended† | mp4 |
| T-LIFE-17 | Signaling Worker reset (redeploy or socket reset) does not drop an established link or the terminal | 0 link drops; 0 replays | M-LINK | S-SIGRESET† | log |

---

## 9. Tabs and adjacent UX (T-TABS)

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-TABS-01 | The grid card shows the page's current content: the live bottom if the page was following (user video 13:50: a stale diff region), the reading position if reading, updated while the grid is open | card matches the page's last frame at grid open (M-ROWS ids equal); while the grid is open and output streams, the card is ≤ 1 s old | M-ROWS on the card crop | S-GRID† (extends `r1-s4`) | mp4, json |
| T-TABS-02 | A card is never blank and never an indefinite skeleton (D5) | a never-opened tab shows a snapshot ≤ 3 s after the grid opens (link up), else a static labeled placeholder (no spinner) | M-VID | S-GRID† | png |
| T-TABS-03 | Shrink-to-grid and zoom-back: no relayout jump; the terminal content scales without reflowing | per frame of the transition: card content position error ≤ 2 pt from the interpolated path; 0 frames where the content reflows (cols change); 0 black frames | M-MOTION on the card, M-BLACK | S-GRID† (×20 while streaming) | mp4, json |
| T-TABS-04 | Card labels never glitch: no split label, no truncation flip, no ghost (user video 13:50 at 1.1-1.5 s: "Res…" + "Chat" and a phantom card for ≥ 8 frames at 20 fps) | 0 frames with a split or ghost label; the label text is constant through the animation | OCR of the label band per frame | S-GRID†, S-NEWTAB-REFUSED† | mp4 |
| T-TABS-05 | Open from the grid: tap → the page at full size with the T-LIFE-03 timing and T-FOLLOW-01 last row | as those rows | as those rows | `last_tab_restore`, `latency tab_switch` | json |
| T-TABS-06 | New terminal from +: one tap, instant, opens a working shell (prompt visible) | prompt visible ≤ 1.5 s p95; 0 placeholder reflow of other cards (U7) | M-VID | S-NEWTAB† | mp4 |
| T-TABS-07 | A refused create (for example "New Claude Chat" refused by the Mac's cwd policy) changes nothing in the grid | 0 phantom cards; 0 label changes; one toast | M-VID, OCR | S-NEWTAB-REFUSED† (video 13:50 repro) | mp4 |
| T-TABS-08 | Close: a tab running an agent or a foreground process asks for confirmation; a plain idle shell closes at once; the Mac's tab closes too | 10 of 10 confirmations shown when Codex runs; 0 for idle shells; Mac tab list matches ≤ 2 s | M-AX, M-MAC | `joystick_paste_close` extended† | json |
| T-TABS-09 | Title pill updates with the process or OSC title and the cwd within 1 s; no light flash on first appearance (U5) | update ≤ 1 s; 0 light-pill frames over a dark page | OCR, pixel | S-TITLE† | mp4 |
| T-TABS-10 | Reorder (if offered by the kit) persists on the Mac and across relaunch | order equal on the Mac and after relaunch | M-MAC | S-REORDER† | json |
| T-TABS-11 | Toasts never cover the title pill, Back, +, or the composer; at most 2 lines; swipe-dismissable; auto-dismiss | bounding boxes disjoint (M-AX); lines ≤ 2; one swipe dismisses (10 of 10); gone ≤ 5 s | M-AX | S-TOAST† | png, json |
| T-TABS-12 | Feed "Answer in Terminal" lands on the right workspace and tab, following at the prompt, with the question visible above the composer | right tab 10 of 10; the agent's question row visible; ≤ 1 s from tap to first correct frame (tab open), ≤ 2 s (tab cold) | M-ROWS, M-AX | `feed_terminal` | mp4 |
| T-TABS-13 | Workspace switch (Back → another workspace → back): each terminal keeps its scroll state and scrollback | anchors kept (± 0 rows); 0 replays when the link stayed up | M-ROWS, M-SIZELOG | S-WSSWITCH† | json |
| T-TABS-14 | Hidden controls: the zoomed card's close button and the thumbnails' live controls are not exposed to accessibility (M8, R4-3) | 0 hidden accessible controls in the AX dump | M-AX | `open_workspace` | txt |

---

## 10. Agents (T-AGENT) and extreme load (T-LOAD)

### 10.1 Fixtures (staged on the Mac by ssh, started by typing on the phone)

Every generator prints numbered rows (`#%07d`) and a send timestamp, and ends
with a CRC total line (M-ROWS, M-INTEG, T-FOLLOW-06).

| Fixture | Content |
| --- | --- |
| `yes2m` | `yes \| head -2000000` (no ids; integrity is checked on the count and the tail) plus `yes-ids`: 2,000,000 numbered rows, the same shape |
| `cat50` | `cat` of a 50 MB file of numbered, colored rows (about 80 cols, SGR every 10 chars) |
| `stream1m` | 1 Mbit/s of colored rows for 10 min (125 KB/s, paced by a token bucket), with a status line redrawn below |
| `stream20` | 20 rows/s with a status line redrawn below (the shape of `scroll_while_streaming`) |
| `line1m` | one 1 MB line with no newline, then a newline and a marker row |
| `altflip` | enters and leaves the alternate screen 20 times per second for 60 s, drawing a numbered frame each time, ending on the main screen with a marker |
| `hist10k` | prints exactly 10,000 numbered rows, then idles |
| `capfill` | prints rows until the phone's scrollback cap is exceeded 3×. The cap today is `scrollback-limit-bytes = 8 MiB` (`CmuxMobileGhosttyApp.swift`), not 10,000 lines. The user named a 10,000-line cap. Both are tested: T-LOAD-CAP-a (10,000 lines) and T-LOAD-CAP-b (the byte cap, about 100k rows at 80 cols). |
| `render-suite` | section 3 |
| `multi10` | the phone opens 10 terminal tabs and starts `stream20` in 5 and `stream1m` in 5 (G-12 launcher; from the phone) |

### 10.2 Agents

S-AGENT-CODEX and S-AGENT-CLAUDE: real Codex CLI and real Claude Code on the
Mac mini, in a real project (`termqa/proj` or larger). Each runs **≥ 60 minutes
of continuous real work**, entered only from the phone, once on `W-D` and once
on `G-D`. Each session must include, at least: 30 prompts; 10 approval prompts
answered from the phone (5 allow, 5 deny); 5 interrupts with Esc and 3 with
^C; 3 resumes (Codex `resume` / Claude `--continue`); 2 link drops; 2
background periods of 10 min; 20 grid round trips; 20 reading sessions of ≥ 30 s
while the agent streams; and a transcript longer than 5,000 rows. The full
session is recorded (split files are fine) and analysed end to end with
M-MOTION, M-BLACK and M-ROWS-lite (OCR contiguity on agent text, since agent
output has no row ids).

| ID | Criterion | Threshold | Measure | Scenario | Artifact |
| --- | --- | --- | --- | --- | --- |
| T-AGENT-01 | No rendering or scrolling defect in a 60-min Codex session: T-FOLLOW-02/04 and T-SCROLL-01/02/03 thresholds over the whole recording | 0 foreign, 0 black, 0 spontaneous reversals, 0 read-row drift; per path | M-MOTION, M-BLACK, OCR | S-AGENT-CODEX | mp4 set, json |
| T-AGENT-02 | The same for Claude Code | as T-AGENT-01 | as above | S-AGENT-CLAUDE | as above |
| T-AGENT-03 | Streaming diffs render as on the Mac (colors, line numbers, wide rows) at 5 checkpoints | 0 differing cells at each checkpoint | M-MAC | both | txt |
| T-AGENT-04 | Approval prompts answered from the phone (Enter, arrows, y/n, number keys) reach the agent, and the agent proceeds | 10 of 10 per session; answer → agent's next output ≤ 1 s (excluding model time, from the Mac log) | M-MAC | both | json |
| T-AGENT-05 | Interrupt: Esc and ^C stop the agent's turn | 8 of 8; the agent's "interrupted" state is shown on the phone ≤ 1 s | M-MAC, OCR | both | json |
| T-AGENT-06 | Resume (`codex resume`, `claude --continue`) restores the transcript; the phone shows it without a blank or foreign frame | 3 of 3; T-LIFE-02 holds | M-BLACK | both | mp4 |
| T-AGENT-07 | Codex's transcript redraws (it erases and redraws its live area, and on resize redraws the transcript) never make the page jump or show blank rows (D2) | 0 jumps > 1 row while following; 0 blank flashes; 0 replays not caused by an allowed resize | M-MOTION, M-SIZELOG | S-AGENT-CODEX | json |
| T-AGENT-08 | The TUI's own scrolling vs the phone's scrollback: in Codex/Claude (main screen with a live area), the phone's scrollback holds the transcript, and the pull reaches its start; in an alternate-screen agent view, a drag scrolls the TUI as wheel or arrow input and never the page (T-SCROLL-12) | transcript start reachable (M-ROWS-lite); 0 cases where a drag scrolls neither | OCR | both | mp4 |
| T-AGENT-09 | Status and Feed items stay in sync with the agent: working/needs-input/done on the phone ≤ 2 s after the Mac state | 100 % of state changes (≥ 40 per session); 0 stale "needs input" after the answer | Feed AX vs the Mac's notification ledger | both + `feed_terminal` | json |
| T-AGENT-10 | Memory flat over the session | phys_footprint growth after the first 10 min ≤ 30 MB total and slope ≤ 2 MB / 10 min; peak ≤ 300 MB (sim) | M-MEM | both | json series |
| T-AGENT-11 | CPU flat over the session | app CPU while the agent is idle and the page is following ≤ 3 % avg over 5 min; while streaming, ≤ 35 % avg (simulator, informative, trend must be flat: slope ≤ 1 %/10 min); device thresholds in T-DEV-04 | M-MEM | both | json |
| T-AGENT-12 | Mac side: `cmux-mobile-host` and daemon memory flat; no channel `overflow` closes; no keepalive timeouts | growth ≤ 20 MB/h each; 0 overflow; 0 keepalive drops | M-MAC, M-LINK | both | log |
| T-AGENT-13 | Three agents in parallel tabs (2 Codex + 1 Claude, 30 min): the active tab meets T-AGENT-01; switching between them meets T-LIFE-03; Feed items land on the right tab | as those rows; 0 misrouted Feed deep links | as those rows | S-AGENT-3† | mp4, json |

### 10.3 Extreme load matrix (T-LOAD)

Each load is crossed with four activities. **F**: follow, untouched for the
load's duration. **R**: scroll up and read for 30 s, fling around for 30 s,
Jump to bottom, three times. **T**: type a 200-char numbered string in the
composer, plus 50 direct keystrokes, during the load. **S**: switch among 3 tabs
via the grid every 3 s, 20 times.

Every cell must meet the **cell thresholds**, unless the load row says
otherwise:

- (1) 0 crashes, 0 relaunches;
- (2) **0 hangs over 250 ms**, and stalls over 100 ms ≤ 1 per minute (M-HANG);
- (3) 0 foreign, 0 black frames; in **R**, 0 px read-row drift (T-SCROLL-01/02);
- (4) in **T**, T-INPUT-02 echo ceilings and T-INPUT-04 integrity (0 lost/dup/reorder);
- (5) in **S**, T-LIFE-03 ×2 (p95 ≤ 300 ms under load) and T-FOLLOW-01 on arrival;
- (6) M-INTEG: 0 lost/dup/garbled rows on the phone at the end (beyond what
  the cap drops by design, which must be the oldest rows only);
- (7) app memory ≤ 450 MB peak (sim), and back within 50 MB of the pre-load
  baseline ≤ 60 s after the load ends;
- (8) the link stays up: 0 keepalive drops, 0 `overflow` closes;
- (9) frame pacing (sim, M-FRAMELOG): main-thread work per frame p99 ≤ 8 ms;
  no CADisplayLink interval over 100 ms that the app caused (main thread busy
  in that interval);
- (10) 0 spurious resizes, 0 replays.

| ID | Load | Paths | Load-specific thresholds |
| --- | --- | --- | --- |
| T-LOAD-01 | `yes2m` / `yes-ids` | all 5 paths | Phone finishes rendering ≤ 3 s after the Mac's generator exits (LAN), ≤ 20 s (`G-R`); final tail = Mac tail |
| T-LOAD-02 | `cat50` | `W-D`, `G-D`, `G-T`, `G-R` | Phone drains ≤ 10 s after the Mac (LAN), ≤ 60 s (`G-R`); ^C mid-cat meets T-INPUT-05 |
| T-LOAD-03 | `stream1m` for 10 min | all 5 paths + netsim P-200, P-LOSS5 | T-FOLLOW-06 lag p95 ≤ 1 s (LAN), ≤ RTT + 1 s (relay/netsim); memory slope ≤ 2 MB/min |
| T-LOAD-04 | `line1m` | `W-D`, `G-D` | No hang > 250 ms while wrapping; correct wrap count (= ceil(1 MB / cols)); Files and Links scan ≤ 200 ms main-thread; the marker row visible |
| T-LOAD-05 | `altflip` | `W-D`, `G-D`, `G-R` | Ends on the main screen with the shell scrollback intact (M-ROWS); scroll mode not stuck in TUI pinning (T-SCROLL-13 after); 0 resizes; black frames allowed only when the generator's frame is blank |
| T-LOAD-06 | `multi10` | `W-D`, `G-D` | Every background tab, when opened, shows its live bottom with 0 lost rows (M-INTEG per tab); active-tab cell thresholds hold; app memory ≤ 450 MB |
| T-LOAD-07 | 3 agents (T-AGENT-13) + `stream1m` in a 4th tab | `W-D`, `G-D` | as T-AGENT-13 |
| T-LOAD-CAP-a | `hist10k`, then stream20 | `W-D`, `G-D` | T-SCROLL-10 reaches #0000001; reading at row 5,000 keeps 0 drift |
| T-LOAD-CAP-b | `capfill` (byte cap exceeded 3×) | `W-D`, `G-D` | When the oldest rows are dropped: a reader anchored at a surviving row keeps 0 drift; a reader anchored at a dropped row moves to the new first row once, with no blank frame; memory flat after the cap (± 20 MB) |
| T-LOAD-NET | stream20 + typing on netsim P-200 (200 ms RTT, 1 % loss), P-LOSS5 (50 ms, 5 % loss), P-BW (1 Mbit/s cap, 100 ms), P-WORST (400 ms, 30 ms jitter, 3 % loss) | `W-T`, `G-T`, `G-R` | T-INPUT-03; 0 lost/dup keystrokes; link stays up through 10 min of P-WORST; no `keepalive timed out` |
| T-LOAD-MEM | Low-memory warning ×5 during `multi10` | `W-D` | 0 crashes; the active tab keeps its scrollback (M-ROWS); non-visible tabs may drop snapshots but redraw on open ≤ T-LIFE-01; memory drops ≥ 20 % after a warning |
| T-LOAD-THERM | Thermal state `serious`/`critical` | device only (T-DEV-06) | — |

Netsim: G-11 must give a way to inject delay, jitter, loss and bandwidth on the
Mac's side of the link without touching the phone build. The design is the
implementer's choice. Both of these are acceptable:

- (a) a DEBUG-only `cmux-mobile-host` netsim file in the tag's isolated config
  directory, read on each datagram for WireGuard UDP/TURN/relay and on each
  data-channel send for WebRTC;
- (b) dummynet (`dnctl` + `pfctl`) on the mini, scoped to the rig's UDP ports
  and the TURN server addresses.

Either way the manifest records the profile, and the `link` log's RTT must
confirm it: measured RTT within ± 20 % of the profile. "Relay only" (the
Developer toggle) forces TURN for `W-T`/`G-T`. `G-R` also needs TURN
suppressed (G-06).

---

## 11. Gaps: tooling the implementer must build before the matching rows can pass

| Gap | Needed for | What to build |
| --- | --- | --- |
| G-01 | §1.1 rule 2; every row whose rig step uses `mac_write` | Port all stimulus in `journey.py` and `tq.py` to phone input (composer paste + Send, `softtype`, key bar). Keep `mac_write` only behind an explicit `oracle_or_fault=` guard that writes a `mac_side_uses` entry. Make `e2e/run.sh` drive a remote Mac (today it runs the Mac on the laptop; `tq.py` does remote). |
| G-02 | T-FOLLOW-02/03, T-SCROLL-01..07, T-TABS-03 | `motion.py`: json output, row-height calibration, M-BLACK built in, M-TOUCH overlay from a rig gesture log, a card-crop mode for the grid, a label-band mode for T-TABS-04. One CLI used by verifiers. |
| G-03 | T-SCROLL-01/02/10/11, T-LIFE-09, T-TABS-01 | M-ROWS: numbered-row fixtures (§10.1) plus an OCR tracker (`ocr.swift`) that reads the visible row ids per frame at ≥ 10 fps (60 fps in 2-s windows around events) and outputs the visible window, contiguity breaks and per-row y. |
| G-04 | T-SCROLL-06, load cell (9), T-DEV-01 | In-app `OSSignposter` intervals (`output-batch`, `apply-scroll`, `draw`) and a CADisplayLink interval log, in DEBUG/Demo only, plus a log-stream collector in the rig. |
| G-05 | load cell (2), T-RES | In-app main-thread watchdog (DEBUG/Demo): logs blocks > 100 ms with a backtrace symbolized offline. |
| G-06 | `G-R` path | A DEBUG Developer option that ignores TURN servers, so WireGuard + Relay only stays on the Worker relay frames (path `relay`), and so that `link` logs `path=relay`. |
| G-07 | T-SIZE-01/02 | A `cause=` field on every `terminal-sizing` resize and mirror-reset line (attach, rotation, kb-tui, width, textsize, reattach, resized-event), plus a summarizer. |
| G-08 | T-INPUT-01..05 | A real-link echo probe: `TerminalBenchProbe` extended to stamp the touch-down and detect the echo by a unique sequence in the real output stream (it works only with the fake daemon today). Output: n, p50/p95/p99 json. |
| G-09 | T-INPUT-04/17, T-LIFE-05/10, load cell (6) | M-INTEG: a CRC fixture plus a DEBUG export of the phone terminal's full text (scrollback + screen), and a checker. |
| G-10 | T-AGENT-10/11, load cell (7) | `tq.app_mem` as a 5-s time series with CPU, slope, peak; plus the Mac-side `cmux-mobile-host`/daemon series over ssh. |
| G-11 | T-LOAD-NET, T-INPUT-03 | Netsim (§10.3). It does not exist: no hostd loss-sim file is in the tree; `simulate_network_loss` (cmux-mobile-link) only blackholes a WireGuard session for the roam probe. |
| G-12 | T-LOAD-06/07, T-AGENT-13 | A phone-driven multi-tab launcher: opens N terminal tabs from + and starts a named fixture in each via the composer. |
| G-13 | S-REND, T-REND-01/02 | `render-suite` fixture and a Mac reference capture at the same cols × rows. |
| G-14 | T-SEL-01/02 | Terminal text selection and copy (not implemented: `selectionRects` returns `[]`). This is a product gap, not only a tooling gap. |
| G-15 | T-LIFE-07 | A headless lock/unlock for the simulator, if one exists; else the row is device-only. |
| G-16 | T-LOAD-MEM | A headless low-memory warning for the simulator (or a DEBUG in-app trigger that runs UIKit's memory-warning path). |
| G-17 | T-REG-* | Red-run tooling: build and install the old SHAs (§13) on the same rig, and a runner that executes each regression scenario on old and new and writes both verdicts. |
| G-18 | T-INPUT-11 | Hardware-keyboard event injection for the simulator (HID), and a key table fixture (`od -c`) on the Mac. |
| G-19 | all † scenarios | Each scenario marked † as a named `journey.py` / `tq.py` step that writes the manifest fields of its rows. |

Until a gap is closed, its rows are `blocked (needs tool)`, never `pass`.

---

## 12. Device-only criteria (T-DEV): never claimed from a simulator

A real iPhone is needed. Per the user's global rules, an agent may use the
user's phone (TapKit) only when the user explicitly asks for real-phone
verification for this task and the phone is connected. Until then these rows are
`blocked (needs device)` and the terminal is reported as **simulator-green,
device-pending**, never "done".

| ID | Criterion | Threshold | Measure |
| --- | --- | --- | --- |
| T-DEV-01 | Hitch trace while flinging in scrollback during stream1m and during a Codex stream (Instruments Animation Hitches, Release-like build) | hitch time ratio ≤ 5 ms/s; 0 hitches > 50 ms; ≤ 1 hitch > 25 ms per 10 s | Instruments trace |
| T-DEV-02 | ProMotion 120 Hz: scrolling and following run at 120 Hz | ≥ 95 % of frames at 8.3 ms intervals during a fling; following does not drop to 60 Hz while streaming unless idle | Instruments / CADisplayLink log |
| T-DEV-03 | Echo latency on device, Wi-Fi LAN and cellular | Wi-Fi: as T-INPUT-01/02; cellular: p95 ≤ RTT + 60 ms | M-ECHO |
| T-DEV-04 | Device CPU and energy over a 60-min Codex session | avg CPU ≤ 20 % following an idle agent page, ≤ 40 % while streaming; energy impact not "Very High" for more than 5 % of samples | Instruments (Energy Log, CPU) |
| T-DEV-05 | Real lock/unlock, ≤ 30 s and 10 min (T-LIFE-07) | as T-LIFE-04/05 | video |
| T-DEV-06 | Thermal `serious`: frame pacing may drop to 60 Hz, but 0 data loss, 0 hangs > 250 ms | as stated | `ProcessInfo.thermalState` log + M-INTEG |
| T-DEV-07 | Dictation into the composer and the terminal | final text exact; 0 partial commits to the Mac | M-MAC |
| T-DEV-08 | Cellular ↔ Wi-Fi roaming mid-stream (WireGuard), and WebRTC ICE restart | T-LIFE-14 thresholds; WebRTC: reconnect ≤ 3 s, 0 lost rows | roam log, M-INTEG |
| T-DEV-09 | Hardware keyboard (Magic Keyboard / Bluetooth): T-INPUT-11 | as T-INPUT-11 | M-MAC |
| T-DEV-10 | The three user videos (§13) reproduced on the user's phone model: red on the old build, green on the new | §13 | device recording |
| T-DEV-11 | Real low-memory pressure with 10 tabs + 3 agents (jetsam not triggered) | 0 terminations over 60 min | device log |

---

## 13. User videos as named regression scenarios (T-REG)

Source: `~/Downloads/ScreenRecording_10-14-2026 <time>_1.MP4`, device
recordings, 1320 × 2868, 60 fps. The frames cited below were extracted with
ffmpeg and analysed with `motion.py` and a lit-pixel test at 30 fps. Red SHA:
the build installed on the user's phone at the time of each video. The
implementer pins it from the phone's installed build number and records it in
the manifest. Candidates by build time:

- 12:59: `~/cmux-mobile-builds/20261014-224d15e90f-prod` (built 12:30);
- 13:37 and 13:50: `224d15e90f` or `20261014-2e1369f054-prod` (built 13:23).

Each scenario must be shown **red on the red SHA and green on the new SHA**, on
the same rig (two machines, real link, real Codex), with the same analyzer. If
a scenario cannot be made red on the old SHA, it is not a reproduction. The
round reports "not reproduced" and keeps trying (round 1 could not reproduce
two of them). It is never counted as passed.

### T-REG-1259 ("12-59-08", 54.6 s; a long Codex session, `gpt-6-astra max`, keyboard up most of the time)

| ID | Defect seen | Frames | Regression criterion |
| --- | --- | --- | --- |
| T-REG-1259-a | At rest, keyboard down, following a working Codex: the whole terminal goes black for 1-2 frames, twice, while the chrome stays | 3.30-3.43 s, 3.67-3.77 s | T-FOLLOW-04: 0 black frames over 10 min following a working Codex (keyboard down) |
| T-REG-1259-b | Keyboard up, following while Codex works ("Working (43s)"): the live area shifts by about 2 rows between consecutive frames, then 2+ frames show only the chrome (terminal blank) | 26.87-27.33 s | T-FOLLOW-02/03/04 with the keyboard up |
| T-REG-1259-c | Scrolling through history while Codex streams: one frame of another region (Codex's prose summary, "Yep, I built it…") between diff frames; a flash with a frame diff of 44.8 against neighbours that are identical (0.0) | about 20.5 s; 23.13 s | T-SCROLL-02: 0 foreign frames |
| T-REG-1259-d | During a long fling, the terminal is black for about 1.9 s in total (48.7-50.6 s), with only a cursor block at top-left and the scroll indicator mid-track: the page reaches a region of blank document rows, then lands at the bottom | 46.07, 48.7-50.6 s | T-SCROLL-10/11: 0 blank region at any offset; T-LIFE-02 |
| T-REG-1259-e | A single black frame mid-session | 40.10-40.17 s | T-FOLLOW-04 |
| T-REG-1259-f | Rapid back-and-forth shifts of 50-120 px every 2-4 frames (0.33-1.27 s). The recording has no touch overlay, so this may be the user's own scrolling. The reproduction must log touches (M-TOUCH) to decide. | 0.33-1.27 s | T-SCROLL-03 (spontaneous); excluded if M-TOUCH shows it was the finger |

### T-REG-1337 ("13-37-00", 13.3 s; Codex idle at "Ask Codex to do anything", near the bottom, keyboard down)

| ID | Defect seen | Frames | Regression criterion |
| --- | --- | --- | --- |
| T-REG-1337-a | Near the bottom with no output, the page oscillates by 2-3 rows up and down across consecutive frames (the frames alternate between two offsets) | 6.5-7.2 s (15 fps strip) | T-SCROLL-03 / T-FOLLOW-02: 0 reversals without a finger |
| T-REG-1337-b | A flash: one frame unlike its neighbours (diff 22.9 against prev-to-next 3.1) | 6.83 s | T-SCROLL-02 |
| T-REG-1337-c | A diff block region (rows 207-218 of the code) shows instead of the bottom for about 2 s, then the bottom returns | about 8-10 s (1-fps samples) | T-SCROLL-02 / T-FOLLOW-01 |
| T-REG-1337-d | "Jump to bottom" appears and disappears while the page sits at the bottom | 0-4 s vs 4-7 s and 10-11 s | T-FOLLOW-05 |
| T-REG-1337-e | A continuous one-direction move of 50-90 px per frame for about 0.5 s, then a reversal (motion analyzer: 3.70-4.17 s) | 3.70-4.17 s | T-SCROLL-03 (unless M-TOUCH shows a fling) |

### T-REG-1350 ("13-50-28", 3.1 s; tab grid of `workspace-1`, one terminal tab with Codex)

| ID | Defect seen | Frames | Regression criterion |
| --- | --- | --- | --- |
| T-REG-1350-a | The grid card shows an old scrolled region (a diff, rows 209-227) instead of the live bottom (Codex's prompt) | the whole video | T-TABS-01 |
| T-REG-1350-b | + → New Claude Chat (refused by the Mac): a phantom larger card appears behind the existing one with a "Chat" label, and the existing label splits into "Res…" and "Chat", then reads "Respond to greeting \|" truncated, for at least 8 frames at 20 fps | 1.10-1.50 s | T-TABS-04, T-TABS-07 (U7) |
| T-REG-1350-c | The refusal toast ("Can't start Claude in this folder from your iPhone yet.") sits just above the bottom toolbar. Its placement is acceptable. Check that it is swipe-dismissable and never covers +, the tab count or the composer. | 1.6-3.1 s | T-TABS-11 |

Also from earlier rounds, each kept as a regression row with its own red SHA:

| ID | Source | Criterion |
| --- | --- | --- |
| T-REG-D1 | qa-round-1 D1 (keyboard hide snaps 31 px back) | T-SIZE-05 |
| T-REG-D2 | D2 (7-row jump while following Codex) | T-FOLLOW-02 |
| T-REG-D3 | D3 (blank + `[unknown surface 10]` on drop) | T-LIFE-08 |
| T-REG-D4 | D4 (two replays per reattach) | T-SIZE-02 |
| T-REG-D5 | D5 (indefinite Connecting skeleton card) | T-TABS-02 |
| T-REG-R32 | R3-2 (black frames over `top` on keyboard change) | T-SIZE-06, T-REND-08 |
| T-REG-R34 | R3-4 (cursor block in the saved relaunch frame; a frame missing its last rows) | T-LIFE-06, T-LIFE-02 |
| T-REG-R35 | R3-5 (key bar hole after swipes) | T-INPUT-10 |
| T-REG-R41 | R4-1 (swipe-back from the key bar) | T-SCROLL-17 |
| T-REG-R42 | R4-2 (Files and Links fragments) | T-SEL-04 |
| T-REG-B1 | SPEC B1 (blank rows above) | T-REND-09 |
| T-REG-ATTACH-TUI | User report 2026-10-21 (iPhone over 5G): opening a Claude Code tab showed an almost black screen with only the spinner line, the cursor and a few status digits, then the whole screen. The attach replay of a full-screen TUI draws its rows from the cursor, which entering the alternate screen copied from the phone's shifted primary screen, so the rows landed below the TUI's rows and only absolutely positioned live updates showed. `TerminalAltScreenReplaySurfaceTests` (real Ghostty surface) | T-LIFE-02, T-AGENT-06 (attach to a running full-screen TUI: the first frame after the held frame has the TUI's whole screen) |
| T-REG-OPEN | terminal-scroll-model.md "open": `scroll_while_streaming` failed 1 in 3 runs (frame 1591) | T-SCROLL-02 must pass **20 of 20** consecutive runs of `scroll_while_streaming` per path |

---

## 14. Adversarial free play (T-ADV)

| ID | Criterion | Threshold |
| --- | --- | --- |
| T-ADV-01 | The verifier's 20-minute free play on S-AGENT-CODEX: mixed gestures, rapid keyboard toggles, grid spam, paste spam, rotation during a fling, drops during a fling | 0 disruptive, 0 noticeable defects (§15); every finding gets a T-REG row |
| T-ADV-02 | Gesture spam: 100 random gestures in 60 s during stream1m (M-TOUCH logged, so the run can be replayed) | cell thresholds (1)-(3), (8), (10) |

---

## 15. Severity rubric

- **Disruptive.** Any of:
  - wrong, lost, duplicated or garbled content;
  - a foreign frame, or a black or blank frame where text should be;
  - spontaneous motion (oscillation, a jump of ≥ 1 row without a finger, read-row drift);
  - a lost, duplicated or misrouted keystroke;
  - a hang over 250 ms, a crash, or a stuck state (Connecting > 10 s with the Mac online, an input that does nothing);
  - an agent that stops on the Mac because of the phone;
  - a spurious resize or extra replay visible as a redraw;
  - the bottom row hidden while following;
  - a Feed deep link to the wrong tab.
- **Noticeable.**
  - Any threshold missed by less than 2× on a timing or latency row.
  - A visible glitch that does not change content: label truncation flip, toast overlap, a one-frame partial frame on handoff, an uneven key bar.
  - A stall of 100-250 ms that is seen.
  - A replay not seen as a redraw.
- **Polish.** A visual nit with no threshold impact. Every polish item is listed
  in the round report with an owner. None blocks the gate, but an item open for
  more than 2 rounds is promoted to noticeable.

A threshold missed by 2× or more is disruptive.

## 16. Exit gate

The terminal passes when **all** of these hold:

1. **Zero disruptive and zero noticeable** findings across sections 3-10, 13
   and 14 on both transports (`W-D`, `G-D` full; relay paths and netsim per
   §10.3), iOS 26.5 and 27.0, with every row's `measured` numbers in the
   manifest.
2. Every T-REG row is shown red on its old SHA and green on the new SHA.
   T-REG-OPEN passes 20/20.
3. No row is `blocked (needs tool)`. Every gap in §11 that a row depends on is
   built and used.
4. **Two consecutive rounds, each from a fresh adversarial verifier**, are
   fully green on the same SHA, or on two SHAs where the second differs only by
   changes the first round asked for, with the whole matrix rerun.
5. Polish items are listed with owners.
6. Device-only rows (§12) are either green from a device run the user
   authorized, or explicitly reported as `blocked (needs device)`. In that case
   the status is "simulator-green, device-pending", and nobody calls the
   terminal done or perfected.

A round that changes any terminal, link or tabs code resets the
consecutive-round count to zero.

## 17. Criteria count

| Area | IDs | Count |
| --- | --- | --- |
| Rendering | T-REND-01..11 | 11 |
| Following | T-FOLLOW-01..06 | 6 |
| Scrolling | T-SCROLL-01..18 | 18 |
| Input | T-INPUT-01..17 | 17 |
| Selection, links, search | T-SEL-01..06 | 6 |
| Sizing | T-SIZE-01..09 | 9 |
| Lifecycle and network | T-LIFE-01..17 | 17 |
| Tabs and adjacent UX | T-TABS-01..14 | 14 |
| Agents | T-AGENT-01..13 | 13 |
| Extreme load | T-LOAD-01..07, CAP-a, CAP-b, NET, MEM, THERM | 12 (each crossed with F/R/T/S and paths; 10 cell thresholds) |
| Device-only | T-DEV-01..11 | 11 |
| User-video regressions | T-REG-1259-a..f, 1337-a..e, 1350-a..c | 14 |
| Earlier-round regressions | T-REG-D1..D5, R32, R34, R35, R41, R42, B1, OPEN | 12 |
| Adversarial | T-ADV-01..02 | 2 |
| **Total** | | **162** |
