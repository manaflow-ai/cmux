# Terminal QA round 3 (termqa, 2026-10-14 16:15-17:00 PT): in progress, handed off at `595ad952`

Input: VERIFY-round2.md (fresh verifier: gate not met; 3 disruptive, 3 noticeable).
Rig unchanged (simulator on the laptop, `cmux-mobile-e2e-604fc689` on `mini-cmuxs-mac-mini-2`,
WireGuard + Relay only, path `turn`), real Codex, phone input only.

## V2-1 (disruptive): Codex's live area garbled after grid round trips

- **Red on `eef46a7c`:** `tq.grid_garble("r5-grid-garble-old")` (one Codex answer of
  60 numbered paragraphs, three grid round trips while it streams, wait for "done").
  Phone's last rows: `… done 4:20 PM`, `columns more complicated.`, `handled according
  to terminal emulation rules.` (stale rows where the prompt and status line belong);
  Mac: `done 4:20 PM`, `› Ask Codex to do anything`, `gpt-6-astra max · …`.
  Video `~/cmux-next-ios-e2e/termqa-raw/r5-grid-garble-old.mp4`.
- **Cause found (log `mirror rows A -> B cause=layout`, added in this round):** the
  grid's zoom lays the page out at 893, 914, 939, 952, 963 pt; the mirror's row count
  (`surfaceRows`, page rows + margins) follows: 151 → 152 → 154 → 155 → 156 → 157.
  Ghostty resizes the mirror on each change, which moves its rows, while the Mac's
  rows map to the mirror's bottom rows by `offset = mirror rows − remote rows`
  (TerminalRowShift). Absolute-addressed writes from Codex then land on the wrong
  rows until the next replay.
- **Attempted fix (not kept):** rows from the screen's height (constant 151). The
  mirror no longer resized during the zoom, but in 2 of 2 runs the page then stayed
  on the start of Codex's answer (visible items 2-13 for 25 s, rows.py at 1 fps on
  `r5-grid-garble-fix1.mp4`) while the Mac streamed to 60, and caught up only after
  the answer finished (no Jump to bottom shown, so the scroll model still claimed
  following). Something else (viewport requests or `presentedTop` matching, which
  assume surface rows ≈ page rows) depends on the mirror following the page height.
  Reverted; only the log line stays.
- **Next:** keep the mirror height fixed AND fix what stalls following with a fixed
  mirror (check `updateViewport`'s margin math and `surfacePresented`'s candidates with
  `-CmuxMobileTermLog`/`-CmuxMobilePresentLog`), or on any mirror row change request a fresh replay
  (reset + reattach) instead of letting Ghostty move rows.

## Other verifier findings, status

| Verifier item | Status |
| --- | --- |
| V2-2 D7 one-frame jumps (14 → 9 per minute at 60 fps) | open (not worked this round) |
| V2-3 link drop loses the reading position | fix-candidate `e242f210` (see below) |
| V2-4 D4 two replays per reattach | open, daemon side; cause found (see below) |
| V2-5 scrollback shrank after a drop (5,460 → 1,026 rows; matches the Mac's history) | open; reproduced once (1,826 → 1,118 rows on the first reattach after a launch; 1,118 → 1,118 on the next) |
| V2-6 RTT spikes 480-2,427 ms without a drop on G-T | open, transport |

## Round 3, second implementer (16:30-17:00 PT)

Merged state: branch already contained `origin/feat-cnx-ios` 981d2d57. CmuxTabsKit
re-synced byte-identical to upstream `f085ad35` (`2c078822`, coordinator request).
Laptop load 72 → 12 during this window (other sessions building): every recording
below is **invalid for timing**; only correctness is claimed. Path G-T only.

| SHA | Change |
| --- | --- |
| `2e5e2ffe` | red test `TerminalMirrorRowsTests` (V2-1) |
| `b98088d2` | V2-1 fix: `TerminalMirrorRows`: the mirror's rows come from the longer screen side + 2 x 48 margin rows (151 on the iPhone 17 Pro), never from the page's transient height; out of a window the rows stay |
| `8f81ea35` | red test `TerminalReadingMarkTests` (V2-3) |
| `e242f210` | V2-3 fix: `TerminalReadingMark`: on a mirror reset while reading, the anchored row and the 5 rows below it are read (text); after the replay is parsed, at Ghostty's next scrollbar report, the rows are found again nearest-first around the same distance from the end (±2,000 rows), else that distance; the held frame stays until then |
| `5cafb1af` (red test), `405bba87`, `595ad952` | D5: a tab whose session was never started (not opened in this launch) shows its saved frame or the static placeholder in the grid, no spinner (`TerminalConnectionState.cardShowsConnecting`) |

Tests: `swift test --filter CmuxMobileTerminalTests` on `mini-cmux11s-mac-mini` (`~/termqa-test`,
git archive of HEAD + the local `CmuxMobileLinkFFI.xcframework`): 116 tests, 30 suites, pass at
`595ad952`. The red side of each new test is a compile failure (new API); the
behavioural red is the rig evidence (`r5-grid-garble-old`, `v2-adv-c/i`, D5 shots).

Rig evidence (`~/cmux-next-ios-e2e/termqa-raw/`, shots in `cmux-next-ios/verify/termqa/artifacts/shots/`):

- **V2-1 green (G-T):** `r6-grid-garble-fix.mp4` (60 paragraphs, 3 grid trips): phone
  bottom = Mac bottom (`done 4:35 PM`, `› Ask Codex to do anything`); rows.py 1 fps:
  the window follows 2-12 → 50-60 in 11 s, no stall (the fix1 failure mode). 0
  `mirror rows` changes during the trips (log). `r6-grid-garble-long.mp4` (200
  paragraphs, 8 trips, 3 of them while streaming): bottom equal, follows 2 → 200, 0
  backsteps. Not yet re-judged by a verifier. Why fix1 stalled was not reproduced; it
  may have differed from this change (its diff was not kept).
- **V2-3 green (G-T):** two drops while reading (`pkill -9` of the rig's cmux-mobile-host):
  OCR of the top 6 rows identical before/after, Jump to bottom shown, 2 of 2
  (`r6-read-drop0/1.mp4`, `r6-read-drop-pre*/post*`). Log: `reading mark restored
  row 1743 -> 1035 of 1118` (the replay was 708 rows shorter: V2-5) and `966 -> 966`.
- **D5 green:** `r6-tabs-grid-d5c` (t2 card: saved frame, no spinner; before:
  `r6-tabs-grid-d5`, "Connecting to cmux's Mac mini (2)…" for 8+ s).
- **T-TABS after the kit sync:** 11 grid round trips worked; T-TABS-14 still **fails**:
  `Close e2e-t1` (30 x 30 at x 372, y 0) is in the AX tree while the page is settled;
  it is TabsKit's (`TabOverview`), already in UPSTREAM-REQUESTS.md; still present in
  `f085ad35`. Other T-TABS rows not re-run.

## D4 / V2-4: cause (daemon, from reading the code; not yet changed)

cmux-mobile-host passes `attach-surface`/`resize-surface` through unchanged
(`cmux-next-ios/rust/crates/cmux-mobile-host/src/services.rs`, `policy.rs`). In the daemon
(cmux-tui), the PTY size is the per-dimension minimum over every attached view
(`cmux-terminal-sizing/src/lib.rs` `Smallest`, the default), so the Mac window's
own grid (39-41 rows) wins over the phone's 42: no off-by-one. A sized attach of a
hosted PTY sends the size to the host and returns at once
(`surface/pty_surface.rs` `resize` → `send_viewer_size`; `surface/geometry.rs`
`pending_resize_completion` is `None` for PTYs), so `cmd_attach.rs` builds the replay
at the old size, then the host's `ResizedWithColors` reaches the phone as `resized`
→ a second reset and replay. Also `commit_client_attach` → `sync_terminal_client_view`
joins the sizing engine after the replay, which can trigger another resize.

Fix to make (daemon): (1) for PTY attaches, wait for the host's resize ack
(`FLAG_VIEWER_SIZE_ACKS`) before `attach_stream_with_lifecycle`, as browser attaches
do; (2) call `sync_terminal_client_view` before the replay; (3) return the
effective cols/rows in the attach reply so the phone stops re-queuing a size the Mac
overrules (`DaemonTerminalSession.swift` re-queues when `lastSize != attachedWithSize`);
(4) fallback: drop a `Resized` that repeats the replay's own size for that tap.
Rust builds on rbx; deploying needs the rig's Mac app (`cmux-mobile-e2e-604fc689` on mini-2)
rebuilt or its bundled `cmux-tui` replaced. V2-5 may share this cause (a PTY resize
makes Codex redraw and truncate its transcript: "Earlier messages are available");
not established.

## Next (in order)

1. A fresh adversarial verifier on `595ad952`+ for V2-1, V2-3, D5 (G-T), with
   ACCEPTANCE.md verbatim; timing rows need a valid environment (below).
2. D4 daemon fix above (test first in cmux-tui), then V2-5 cause.
3. V2-2/D7 one-frame jumps; D10, D1, D6, D11, D12; V2-6 with the WireGuard roaming code.
4. Timing environment: run the simulator on a cmux mini or `scripts/verify-remote.sh
   ios` (AWS), or gate captures on load < 12 and record load beside each artifact;
   G-04 in-app frame log first.
5. Paths W-D, G-D, G-R; 60-minute Codex and Claude Code sessions per path; G-17 and
   the other tools in ACCEPTANCE §11; G-14 text selection.
