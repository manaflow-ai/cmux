# Terminal QA round 6 (termqa, 2026-10-14 22:40 PT onward, in progress)

Input: qa-round-5.md (`d66a8718`), VERIFY-round5.md (origin/feat-cnx-ios-termverify5 `18b62b51`,
REJECT on `c622a001`). origin/feat-cnx-ios `aebd1427` merged first (fast-forward: browser and video work).
Laptop load 30-35 during this round: no timing claims from the rig.

## Status

| Item | Severity | Status | Evidence |
| --- | --- | --- | --- |
| Scroll while streaming: per-frame pixel read on the main thread | disruptive (user report) | **fixed for reading; following still reads** (red `3d79af9c`, green `64171fe1`) | below |
| V2-3 eviction: reading place lost when the Mac's history prunes at the top | disruptive | **fixed, rig 2 of 2** (red `6ec8e224`, green `263c9feb`) | below |
| V5-2 upward fling ends at the live bottom | disruptive | **cause found and fixed** (same commits); 0 of ~42 rig flings during prunes | below |
| PR 20809 daemon tests | - | **flake, not the PR**: green on the new head | below |
| V5-1 black frame on Jump to bottom | disruptive | **fixed for Jump, rig 3 of 3** (red `b91fca68`, `5832bacf`); the reattach case (s4) not re-run | below |
| V5-6 / T-TABS-01 card crops the live bottom | noticeable | **fixed for inactive cards** (red `dc875945`, `5832bacf`); **active card still the kit's top crop** | below |
| Bottom pin on the rig (real output) | | **holds**: `gap 0.0 pt` on every settle in r6-jump-10 | `artifacts/r6-jump-10.log` |
| D7 Codex follow re-check, V5-4, V5-5, D1, D11, D12, V2-6, D10, D6, T-LIFE-08, 60-min sessions, G-14, G-17, link-status reader | | **not done this round** | Next |

### Scroll while streaming (main-thread pixel read)

The pixel read placed every frame (`present`, 1.07 ms a frame on the simulator). While the page reads
scrollback, Ghostty never moves the viewport on its own. A read frame that matched the requested and
reported viewport now confirms it (`TerminalPresentMatch.confirmed`), and later frames are placed there
with no read (`knownTop`) until a request, a report or the surface's `viewportEpoch` (scroll binding,
resize, font size) changes. Following still reads every frame (D7: Ghostty follows on its own and
stale frames arrive). Tests: `TerminalPresentMatchTests` (3 new).

`jank.sh` on `cmux-mobile-termqa-impl` (60 Hz simulator, `stream 6000 8`, 8 flings), `framesum.py` now prints
work p99 and per-signpost costs:

| Phase | Frames | Hitches | Work p50 / p95 / p99 (ms) | `present` mean | pixel reads |
| --- | --- | --- | --- | --- | --- |
| interacting+streaming, before (`fc192319`, round 5) | 1076 | 0 | 1.02 / 2.05 / - | 1.07 ms | every frame |
| interacting+streaming, after (`64171fe1`) | 1124 | 2 (load 34) | 0.13 / 0.26 / 0.79 | 0.044 ms | 41 of 1115 |
| following+streaming, after | 502 | 4 | 0.97 / 2.94 / 3.36 | 1.42 ms | every frame |

Following at p99 3.36 ms is under the 4 ms target but not well under; next step is a band-limited read
(only the rows near the visible band). Device timing remains T-DEV.

### V2-3 eviction and V5-2 (one cause)

At the scrollback cap Ghostty prunes a page of its oldest rows (887 rows on the rig): the total and a
scrollback viewport's reported top drop by the same count while the rows on screen stay. The phone kept
the reading anchor, presented and requested tops, document and offset in the old numbering, so:
- a reset read the mark at the old row number, 887 rows lower in the text (`restored row 15047 -> 15047`);
- during a fling the full re-measure shrank the document under the offset; UIKit clamped it to the end,
  the deceleration ended there, and the page followed (V5-2's "a fling reached the bottom", and the
  black frame between the clamp and the next placement).

Fix: `TerminalHistoryPrune.prunedRows` recognizes a prune report (history shrank, the viewport top fell by
the shrink plus rows appended, no request in flight, not following, not a `clear`), and
`historyPruned` moves every held row and the offset in one transaction (`TerminalScrollModel.shiftRows`).
Also: the touched-bottom slack (8 rows) applies only when the gesture's last move above the bottom edge
was downward; an upward fling from the live bottom that rests 5 rows up now reads.
Tests: `TerminalHistoryPruneTests` (5). CmuxMobileKit on mini-cmux11s: 26 of 26 in the five scroll suites.

Rig (`cmux-mobile-termqa-1`, `263c9feb` Demo build, real link, `evict.py`, every command typed on the phone):

| Run | Prunes while reading | Before drop (top rows) | After reattach | Mark log |
| --- | --- | --- | --- | --- |
| r6-evict-1 (30k-row fill, GEN loop, 12 flings, hostd kill) | 4 x 887 | GEN-2842..2847 | GEN-2842..2847 | `restored row 11991 -> 11991 of 17160` |
| r6-evict-2 (GEN loop, 30 flings, kill) | 4 x 887 | GEN-681..686 | GEN-681..686 | `restored row 10286 -> 10286 of 17614` |

No `a fling reached the bottom` in 42 flings across both runs.

### V5-1 (Jump to bottom black frame)

The offset moved to the live end at once while the surface still showed the scrollback rows, so the page
was black until Ghostty presented the end. Now a scroll whose visible rows share none with the frame on
screen (`TerminalFrameCover.isDisjoint`, rows past the document end not counted) requests the viewport and
moves with the frame that shows it (6-frame fallback). Following output keeps its own rule.
`-CmuxMobileNoJumpAwait` turns the rule off for A/B.

A first version (`5aa8d259`: wait whenever the frame did not cover every target row) was wrong: it
waited during ordinary follows too and the rig showed 3.5 s black runs after each jump (r6-jump-1). It
was replaced before any handoff.

Rig, `rigjump.py r6-jump-10` (GEN loop streaming, 3 trips of 5 flings into history, then Scroll to
bottom), 60 fps motion: **0 black runs, 0 flashes** after the recording warm-up; 3 of 3 jumps logged.
(The recording's gap fraction is 3.3 %, over the 2 % validity line, so this is not a timing claim.)

### V5-6 / T-TABS-01 (cards)

TabsKit lays a page-sized card out top-aligned and shows its top `249.3 / 177` of the width, so a card
showed the page's top two thirds. `TerminalCardCrop` places a terminal card's snapshot with its bottom at
the card's bottom edge: the newest rows and the composer show (`artifacts/shots/r6-grid-cards2.jpg`,
e2e-t2 shows GEN-5974..6000 and the composer).

The active card is the live page (the kit's U4). Offering the snapshot as the static card on the settled
grid (`showStaticCard`) showed a **black** terminal under the composer on the rig
(`r6-grid-cards.jpg`): the active page's `drawHierarchy` snapshot at `prepareCard` does not capture the
surface there. That path is off (`-CmuxMobileStaticActiveCard` to try it); the active card remains the kit's top
crop until U4 or a surface-level snapshot.

### Rig tooling

- **axe hung** on the rig simulator: `axe tap` (default `--tap-style automatic`, which asks accessibility
  first) timed out after 25 s, even with the app terminated; swipes then hung too. `Sim.tap` now passes
  `--tap-style simulator`. A `simctl shutdown`/`boot` of `cmux-mobile-termqa-1` cleared the stuck state (the app
  stayed paired; no keychain prompt). Swipes that end on the soft keyboard also hang axe: scripts hide the
  keyboard first.

### PR 20809

Attempt 1 of run 38678417607 failed `hookToolCallsReachTheTabAndTurnEndClearsThem` (`timed out: reading
presence`, 13 s, with ~40 live-daemon tests in parallel); attempt 2 was cancelled before it started (no
runner; the run cannot be retried). The PR changes only daemon attach sizing; the test's attach and hook
command completed (its sentinel came back), and the 10 s wait was for the presence event. Merged
origin/feat-cmux-next (120 commits, clean) as `c53859d8`: `cmux-next daemon tests (same-tree)` passed.
`cmux app scheme compile (Debug)` failed on a runner disk refusal (`24.1 GiB free, 30 GiB required`);
re-run requested. Not merged.

### Rig notes

- The `aebd1427` merge changed the link library's FFI. The checkout's `CmuxMobileLinkFFI.xcframework` was stale
  (key `f37eae99…`), and the app failed every dial with `rustPanic("Failed to convert arg 'options'")`.
  The cached xcframework for the new key `d84db41c…` fixed it. A rig rebuild after a merge must refresh it
  (`verify/e2e/e2e.py ensure_xcframework`).
- `killtest.py` killed every `cmux-mobile-host` on mini-2, including another agent's (`feedperf-9063df14`). It now
  kills only the rig's by its app path.
- mini-2's data volume is 99 % full (6.8 GiB free).

## SHAs

| Branch | SHA | Change |
| --- | --- | --- |
| feat-cnx-ios-termqa | `3d79af9c` red, `64171fe1` | steady viewport: no pixel read while reading |
| feat-cnx-ios-termqa | `6ec8e224` red, `263c9feb` | history prune shift (V2-3 eviction), downward-only touched-bottom (V5-2) |
| feat-cnx-ios-termqa | `b91fca68` red, `5aa8d259` (replaced), `dc875945` red, `5832bacf`, this commit | V5-1 jump rule, V5-6 card crop, rigjump.py, axe tap style; static active card off |
| feat-cmux-next-tui-attach-size (PR 20809) | `c53859d8` | merge of origin/feat-cmux-next |

## Rig state

`cmux-mobile-termqa-1` (rebooted 00:38 PT) runs this branch's head Demo build (CmuxMobileLinkFFI `d84db41c…`), paired,
open on the e2e-143502 grid with e2e-t1 active. e2e-t2's history is at the cap (HIST/GEN loops).
Mac side unchanged from round 5 (`cmux-mobile-e2e-604fc689` on mini-2).

## Next (in order)

1. D7 rig re-check: a 60 s Codex follow in e2e-t1 at 60 fps (`motion.py`), plus Jump to bottom mid-fling
   on Codex output.
2. V5-1 at a reattach (s4: two drops 3.4 s apart): the held frame and the replay, not the jump rule.
3. Active card (V5-6): a snapshot that captures the Ghostty surface (IOSurface contents, not
   `drawHierarchy`), then `showStaticCard`.
4. V5-4 / D4 rows 39 vs 42 (Mac side), V5-5 closed tab's terminal lingering.
5. D1, D11, D12 (the launch screen is already black in dark mode: `LaunchBackground` has a dark
   appearance, checked 0.35 s after launch on `cmux-mobile-termqa-impl` in dark mode: `round6/d12-launch-dark.png`; the white screen is light mode with a dark terminal tab, a design decision), D6, D10,
   V2-6, T-LIFE-08, 60-minute Codex and Claude Code sessions, G-14, G-17, the link-status reader.
6. Following still reads pixels every frame (p99 3.36 ms on the simulator): band-limited read next.
7. PR 20809: re-run of the disk-refused compile job requested on run 38690447375.
