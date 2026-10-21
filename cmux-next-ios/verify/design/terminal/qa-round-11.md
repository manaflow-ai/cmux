# Terminal QA round 11 (termqa implementer, 2026-10-15 04:20 PT onward)

Input: qa-round-10.md (`b763a1a5`) and VERIFY-round8.md (`origin/feat-cnx-ios-termverify8` `e0789e41`).
`origin/feat-cnx-ios` was already merged (`b763a1a5` = its head). Laptop load 50-140 at the start: no
timing claims.

Code fixes for coordinator items 2, 5, 6, 7a (rendering) and 3, 4, 7b (tabs) run in two sibling
worktrees/branches, `feat-cnx-ios-termqa-render` and `feat-cnx-ios-termqa-tabs`, merged here when done.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| 1. T-LIFE-09/15 (`60dc5462`) on the rig | **green, 10 of 10**: G-D 5 runs (read1 ×2, read2 ×3), W-T 5 runs (read1 ×2, read2 ×3); top row id before = after +12 s = after +15 s in every run (OCR, GEN ids), one G-D run judged by the log only (OCR read the `seq` rows); the restore keeps the row or moves it by exactly the prune (`15721 -> 14834` with an 887-row prune). Build b0b88bc7 | `qa11/{gd,wt}-read{1,2}-*-result.json` |
| 1b. One-frame black at a reattach (new) | **found** in `wt-read2-a` (1 of 10 runs, 13 ms, at the 2nd reattach's mirror reset); **fixed** `aae30f1f` (red) / `af867ded`; on 8727acee 3 more W-T drops (read2 ×2, read1): 0 black, 0 blank, same top row (T-LIFE-09 13 of 13 overall) | `qa11/wt-read2-a-12.19s-oneframe-black.jpg` |
| 2. One-frame black at Jump to bottom | **green on 8727acee: 0 black source frames in 120 jumps** at the cap on W-T (wt-fling-e, wt-fling-f; 89 prunes; 0 snaps, 0 `fling reached the bottom`). History: b0b88bc7 3/60, 246ef796 2/60 (`7b3ae4ec`/`eec85bd4`), 2e205166 4 runs of 3 frames in 120 (the gate let the end's request be replaced by the reader's rows; `87cfd72e` red / `e5e9fda8`: every request while a move waits is for its target, the 300 ms fallback never moves into uncovered rows, the pill hides at once). **Not checked yet**: the ≤ 400 ms landing (load 17-60, timing invalid) and that the pill is gone in the first frame after the tap. Prune while following: 0 black in 150 s, 9 prunes (wt-hold-a) | `qa11/wt-fling-b-*-jump-black.jpg` |
| 3. V5-5 / T-TABS-08 | **green 3 of 3** (idle shell): + → New Terminal, close its card: no confirmation, the Mac's `terminal list` drops it 0.52-0.55 s after the tap. Fix `efaaaf09` (red) / `1c1692c8`: the phone sends `close-terminal` after `close-surface` | `events.jsonl` `close_tab` |
| 4. T-TABS-01 inactive card | **green 1 of 1 on 2e205166** (`card-b`): typed in t1 `clear; sleep 15; seq 1 60; echo CARD-AFTER-…`, app killed, marker printed on the Mac, relaunch, grid first: the t1 card shows rows 31..60, the marker and the prompt 1.1 s after the grid opened; no composer inside any card. On 246ef796 the card cropped its bottom ~10 rows and the active card drew the composer mid-card (`card-a`, `grid-composer-in-card.jpg`); fixed `c68cb316`/`8ac4e62d` and `6a13e7ec`/`cc1f3e0f`. Needs more samples (Codex tabs) | `qa11/card-b-settled.jpg` |
| 5. ~15 s saved-frame hitch | **green on the frame log**: wt-hold-a (W-T, 150 s following at the cap): 0 frames > 100 ms (max 45.6 ms; round 8: 150-214 ms every 15.1 s). The save's main-thread part is now counted (`frame-save` 17-28 ms every 15 s, in `work_ms`): still one long frame's worth of work every 15 s | `qa11/wt-hold-a-framelog.json` |
| 6. Frame-log `blank` | **agrees with the video** in every run so far: 0 flagged where the video has 0 black (wt-hold-a 9579 frames, 9 of 10 drop runs); 1 flagged where the video had the one black frame (wt-read2-a) | |
| 7a. Saved relaunch frame hides the glyph under the cursor | **green 1 of 1** on 2e205166: `printf %s\\r XQZW-glyph; read x` (cursor on X), kill, relaunch: the dimmed saved frame reads `XQZW-glyph` with the X kept | `qa11/d11-glyph-sheet.jpg` |
| 7b. "WireGuard TURN" while hostd says Direct | **no phone bug**: with Relay only on the path is TURN; hostd's label was wrong and is fixed in cmux-mobile-link `0b6e4f61`/`e8d42d40` (the rig's hostd `604fc689` is older). Pin test `99734367`. Also seen on the rig: hostd logs `kind=WireGuard path=Relay` while Relay only is off and the phone says "WireGuard direct" | |
| D6 Continue (coordinator) | fix `f1bc78f9` (test) / `906b9799`: one button `setup.pair-mac.cta`, label/style change only; 1 of 1 first tap advanced on b0b88bc7 (load 38). Loaded-simulator probe not run yet | |
| journey.py "Home" row (coordinator) | fixed `7949c462`: the Mac rows of kind `home` are left out | |
| 8. G-14 on the simulator | **`g14.py scroll` green** (copy exact: a contiguous piece of the printed rows; the page autoscrolled 10 rows under the start handle); **`g14.py tui` (vim) green** on recomputation (5 rows, exact up to the trailing blanks the copy drops, pressed row first). g14.py fixed: partial first/last rows count as exact, vim gets plain 40-column rows and `-n`, and exits with Control z (a pasted `:q!` arrives as bracketed paste and is inserted). htop, T-SEL ×10, selection colour, the clear case: **not run** | `design/terminal/g14/` |
| 9-10 | not started | |

Other: the round-9 rig on mini-cmux10s (`~/cmux-next-ios-e2e/termqa-impl9`) was quit and its leftover helpers killed (coordinator note: a broad pkill there may have restarted its terminals). The shared simulator `cmux-mobile-termqa-1` was wedged (SpringBoard blocked on LaunchServices, containermanagerd not running; `simctl` install/terminate hung): shut down, **erased**, booted headless and set up again with `rigsetup.py` (new seed workspace, same names e2e-t1/e2e-t2).

## Rig

- Shared rig: `cmux-mobile-e2e-604fc689` on mini-2, simulator `cmux-mobile-termqa-1` (C906E217…). Shut down and booted
  headless at the start (the verifier's taps had timed out). The verifier's GEN loop in e2e-t2 had
  already ended (`GEN-60000`, prompt).
- Tools: `verify/termqa/q11.py` (the verifier's `v8v.py` wrapper, evidence to `qa11/`, raw video to
  `~/cmux-next-ios-e2e/termqa-raw/tq11/`; `q11.py install APP` installs a tagged build, launches it with
  `-CmuxMobileFrameLog YES` and opens e2e-t2). The verifier's `v8v_*.py` tools are taken as is.
- Phone builds: `~/cmux-next-ios-e2e/impl11/<sha>/CmuxMobileApp.app`, tag tq10 (`dev.cmux.mobile.tq10`), selected with
  `TQ_BUNDLE=dev.cmux.mobile.tq10`.

## Next (handoff)

The rig is left as: `cmux-mobile-termqa-1` booted headless running build `8727acee` (tag tq10, bundle
`dev.cmux.mobile.tq10`, `-CmuxMobileFrameLog YES`), on tab e2e-t2 of the new seed workspace, transport
**WebRTC with Relay only on (W-T)**; `termqa-state.json` `app_path` = `~/cmux-next-ios-e2e/impl11/8727acee/CmuxMobileApp.app`.
Use `TQ_BUNDLE=dev.cmux.mobile.tq10` with every tool. The simulator stops taking taps under load (load
50+): shut it down (kill its `launchd_sim` if `simctl shutdown` hangs), boot, and wait with
`simctl bootstatus` under an alarm; if `simctl` install/terminate hang after boot, erase and run
`rigsetup.py` (it did here once).

1. Jump to bottom on 8727acee: check the ≤ 400 ms landing and that the pill is gone in the first frame
   after the tap (frame sheets of wt-fling-e/f around `jump_taps_v`), and run on G-D too.
2. T-TABS-01 on Codex tabs (several relaunches); T-TABS-08 with Codex running (10 confirmations).
3. The `frame-save` work (17-28 ms on the main thread every 15 s while streaming) is one long frame's
   worth; make it cheaper or skip it while following and streaming.
4. hostd label: the rig's hostd (`604fc689`) logs `kind=WireGuard path=Relay` with Relay only off while
   the phone says "WireGuard direct"; needs a hostd with `e8d42d40` on the rig to judge.
5. Item 8: htop (G-14), T-SEL ×10 with the blue selection, T-SEL-02, the clear-that-keeps-history case;
   D6 on a deliberately loaded simulator (fix `906b9799`).
6. Items 9-10 unchanged from qa-round-10 (G-17 1350-a/b and 1259 with real Codex on the laptop rig,
   V6-5, D10, V2-6, 60-minute sessions per transport, D7).
