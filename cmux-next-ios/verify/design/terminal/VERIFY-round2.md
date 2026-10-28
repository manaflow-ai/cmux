# Terminal verification, round 2 (fresh adversarial verifier)

Verifier: a fresh session that did not implement anything and did not verify an
earlier round. Gate: `ACCEPTANCE.md` (unchanged). Under test: `feat-cnx-ios-termqa`
HEAD `9da6c4c2dc4f` (terminal code at `6d6f7f329dbd`). Implementer claims tested:
`qa-round-1.md`, `qa-round-2.md`. Date 2026-10-14, 15:48-16:20 PT.

## Verdict

**Gate not met.** 3 disruptive and 3 noticeable defects found (section 3). Most
rows are `blocked (needs tool)` because gaps G-03, G-04, G-05, G-08, G-09,
G-10, G-11, G-12, G-13, G-17 are not built, and every recording this round
(the implementer's and mine) is `invalid` for timing and frame-count rows under
§1.4 (source fps under 30 effective, 14-37 % of gaps > 34 ms). Device rows are
`blocked (needs device)`. No row in this report is a gate pass.

## 1. Rig and evidence rules

- Phone: headless iPhone 17 Pro simulator `C906E217…`, iOS 26.5, `dev.cmux.mobile`
  (installed from HEAD per the rig state), signed in. iOS 27.0 not run.
- Mac: real tagged cmux-next app `cmux-mobile-e2e-604fc689` on `mini-cmuxs-mac-mini-2`,
  real Codex CLI (`gpt-6-astra max`) in tab `e2e-t1`, workspace `e2e-143502`.
- Path: the phone's `link` log reports `wireGuard, path turn` for every connect
  in my window, so this round's live evidence is **G-T only**. It is not G-R (G-06
  not built) and not W-D/G-D.
- Stimulus: every prompt, key, approval and interrupt was entered on the phone
  (composer paste + Send, key bar Escape / Control C / Down Arrow, empty Send for
  Return). Mac-side uses: oracle reads (`terminal screen read`, `terminal history
  read`), and fault injection (`pkill -9 cmux-mobile-host`, 4 times: 15:59:38, 15:59:56,
  ~16:01, ~16:14). No `mac_write`.
- Laptop 1-min load: 5.5-13.1 during my window (13.1 at 16:16, over the §0 limit
  of 12): timing rows are invalid regardless.
- Analyzer: `cmux-next-ios/verify/termqa/motion.py` at HEAD, rerun by me on every
  video, with my touch log (`--touch`) for my own videos. JSON and touch logs are
  under `/tmp/vr2/` on the laptop (not committed; regenerate with the command
  in each row).

My videos (`~/cmux-next-ios-e2e/termqa-raw/`, sha256 prefix):

| File | sha256 | Content |
| --- | --- | --- |
| `v2-adv-a.mp4` | f56a461adf18 | follow, 2 read holds, 3 flings, Jump, 3 keyboard toggles, 3 grid round trips (Codex thinking, then streaming) |
| `v2-adv-b.mp4` | 57bb89e558fe | 4 grid round trips during a Codex turn |
| `v2-adv-c.mp4` | 2f83e33a997e | follow, 30 s read while streaming, 4 flings, Jump, 5 rapid keyboard toggles, drop while following, drop while reading |
| `v2-adv-d.mp4` | c0b719023ae3 | 12 flings to the top of history after the drops |
| `v2-adv-e.mp4` | fdf9d51c4f8f | Esc interrupt mid-turn, ^C at idle (quit Codex) |
| `v2-adv-f-resume.mp4` | 5e6591169f61 | `codex … resume --last` from the phone |
| `v2-adv-g-approve.mp4` | e1b68a8b3b33 | background 12 s during a turn, approval prompt rendered |
| `v2-adv-h-approve2.mp4` | 8b7fecef2508 | approve (Return), then deny (Down, Down, Return) |
| `v2-adv-i.mp4` | 287a0f602c73 | grid ×2 and background 10 s while streaming, read + drop mid-stream, flings, Jump |

Free play on the live rig: 15:52-16:15 (23 min), real Codex streaming in most of it.

## 2. Implementer claims re-checked

| Claim | My result | Status |
| --- | --- | --- |
| D7 fixed in `ae5cf4e7`: 60 s follow before/after "3 → 0 flashes, 5 → 0 down moves, 35 → 0 reversals" (`r2-turn-follow60-before/after.mp4`) | motion.py at HEAD: **before** 14 flashes (all one-frame 1-3 row jumps), 148 reversals; **after** 9 flashes (7 of them ±1 row, plus −80 pt and −32 pt at 57.6 s), 127 reversals, 1058 moves. Both recordings `INVALID` (44.0 and 47.8 source fps, 21 % / 17 % gaps > 34 ms). Frame check on source frames of the after video, pts 16.483 → 16.522 → 16.550 s: the page moves up one row and shows row 207, the next frame moves **back down one row with 207 gone**, then up again. This is exactly the D7 shape. | **not reproduced; D7 still present in the after video** |
| D3 fixed (no blank, no error text on a drop) | `r2-s5-link-drop-stream`: 0 black; `r2-s5b-link-drop-idle`: 0 black (8.7 fps, invalid); `r1-s5` (old build) 109 black frames at 5.18-6.98 s (the red side). My 4 drops: the held frame with "Reattaching…" stays; no error text seen. motion.py flagged 2-frame black runs at `v2-adv-c` 91.20 s and `v2-adv-i` 62.12 s that I could not find on the source frames (sparse VFR frames); treat as unconfirmed. | consistent with the claim (G-T only, invalid fps) |
| D8 "partly fixed": reattach at the Mac's 53x39 | The log says `reattach at the Mac's 53x39 (asked 53x42 was overruled)` and then, 70 ms later, `mirror reset cause=reattach size=53x42`, then `mirror reset cause=resized-event (rows 39…)`. The phone mirror is reset at 42 rows while the Mac PTY is 39 rows (Mac `screen read`: 39 rows × 53 cols). The garbled live area of D8 reproduces at HEAD without any replay (V2-1). `r3-wg-lifecycle.mp4` 40-48 s shows the same stuck row (`218.` held above "Ask Codex" while the stream is at 240+); motion.py marks 20 flashes there. | **not fixed** |
| D9 fixed (one reset per open from the grid) | 0 `resize` lines and 0 mirror resets on 12 grid opens in my window. | consistent |
| D4 open (2 replays per reattach) | 4 of 4 drops: surface 10 got `cause=reattach` then `cause=resized-event`. | confirmed open |
| T-SIZE-01, no spurious resizes | 0 `resize … cause=` lines in my whole window (scrolls, flings, 8 keyboard toggles, 12 grid trips, 2 backgrounds, 4 reattaches). | consistent (G-T, my window only) |
| Esc interrupt works from the key bar | Esc mid-turn: Mac shows "Conversation interrupted" (first read 2.39 s after the tap, screen read takes ~1 s, not a timing). | consistent |
| Approvals from the phone | 1 allow (empty Send = Return), 1 deny (key bar Down ×2 + Return); file created / not deleted on the Mac. | consistent (2 of 2; the row needs 10) |

Other implementer videos (motion.py at HEAD, all `INVALID` on fps): `r4-wg-lifecycle`
293 moves, 81 reversals, 0 flashes, 3 black frames at 33.85 s (not visible on the
source frames I extracted; unconfirmed); `r4-tabswitch-lag` 0 flashes, 0 black,
13 reversals (finger-driven around 5.3 s and 14.8 s); `r1-s5` 10 flashes,
109 black (old build, expected red).

## 3. Defects

### Disruptive

**V2-1. Codex's live area on the phone is garbled after a tab-grid round trip,
and the garbage stays until the next replay.** (T-FOLLOW-04, T-AGENT-01/03/07,
T-TABS-05; same class as D8)
- Repro: Codex working (thinking or streaming) in `e2e-t1`, keyboard down; tap
  Tabs, tap the `e2e-t1` card; repeat 1-3 times. Reproduced in 3 of 3 sessions
  (first garble after trip 1, 2 and 1).
- Seen: stale status rows from earlier in the turn ("Noting course change and
  shelter (1m 31s …" above the current "Confirming land sighting (2m 34s …"),
  a junk row `•                     8`, the `›` of "Ask Codex" missing, blank rows
  missing, the cursor block on its own row; later, rows of earlier content stuck
  above the prompt ("meadow filled with wildflowers.", "5. Granite boulders marked
  the route toward a") under item 141 while the Mac shows 142. It survives a
  background (`v2-i-bg`) and the end of the turn ("Worked for 2m 50s · done" with
  the stale rows under it at `v2-adv-c` 90.9-91.6 s) and clears only on a replay.
- Evidence: `v2-adv-a.mp4` from ~85 s to the end (grid trip at ~84 s; 1-fps sheet
  shows the switch), `v2-adv-b.mp4` after trips 2 and 3, `v2-adv-i.mp4` after the
  grid at ~10-20 s; phone vs Mac screenshots `artifacts/shots/v2-a-after2.jpg`,
  `v2-b1.jpg`, `v2-i-grid.jpg` (rig-local, not committed) with the Mac's `screen read`
  printed in the session transcript.
- Likely cause (to confirm): the phone's mirror is 53x42 while the Mac PTY is
  53x39, so Codex's cursor-relative redraws of its live area land on other rows on
  the phone. The log line `mirror reset cause=reattach size=53x42` right after
  `reattach at the Mac's 53x39` shows the mismatch.

**V2-2. D7 is still present: a one-frame 1-row backward jump while following a
stream.** (T-FOLLOW-02/03, T-REG-D2 shape)
- Evidence: `r2-turn-follow60-after.mp4` (the implementer's "after" video) source
  frames at 16.483 / 16.522 / 16.550 s; motion.py lists 7 one-row jump flashes in
  that video (16.52, 18.22, 33.72, 35.20, 39.78, 43.68, 51.68 s). In my live
  session `v2-adv-a.mp4` has 16 jump flashes and `v2-adv-i.mp4` 5 (all
  recordings invalid on fps, so the counts are indicative; the 16.5 s case is
  verified frame by frame).
- Repro: follow a Codex answer that streams numbered lines, keyboard down, no
  finger, 60 s.

**V2-3. A link drop loses the reading position: the page comes back at the live
bottom.** (T-LIFE-09 needs the same top row ± 0)
- Repro: while Codex streams (or right after), drag up ~1 screen and let go
  (the log says `settled -> reading(anchor row 1039…)`); kill `cmux-mobile-host` on the
  Mac; after "Reattaching…" the page shows the live bottom and Jump to bottom is
  gone. 2 of 2 (`v2-adv-c.mp4` drop at 15:59:56; `v2-adv-i.mp4` drop at ~16:14:09;
  screenshots `v2-c-preread` / `v2-c-postread`, `v2-i-preread` / `v2-i-postread`).

### Noticeable

**V2-4. Two replays per reattach (D4).** 4 of 4 drops: `cause=reattach` then
`cause=resized-event (rows 39, last size asked 53x42)` on surface 10. T-SIZE-02
needs 1. Not seen as a separate redraw in the recordings (noticeable, not
disruptive).

**V2-5. The phone's scrollback shrank on a reconnect.** Before the first drop the
document bottom was 81,932 pt (~5,460 rows); after the reattach it was 15,388 pt
(~1,026 rows), and the top of history is Codex's "Earlier messages are available
— press ctrl + t to view the full transcript" at item 280. The Mac's history also
begins there now, so phone = Mac after the replay, but before the drop the phone
held rows the Mac no longer had, and the reader loses ~4,400 rows on a drop. A
drop at idle afterwards did not change the Mac's history (967 rows before and
after), so the drop alone does not make Codex truncate; when Codex truncated is
not established. Needs a cause before it can be classed; listed as noticeable.

**V2-6. Link RTT spikes on G-T without a drop.** `rttMillis` 480, 953 and 2,427
(n = 26 connects, p50 15 ms) in the phone's `link` log during free play; matches
the implementer's D10 lag report. Noticeable until explained (T-FOLLOW-06,
T-AGENT-12 cannot be checked without G-03/G-10).

### To check (not counted)

- AX lists a `Close e2e-t1` button (identifier `workspace.<uuid>`) while the
  terminal page is shown (T-TABS-14). It may be the zoomed card's hidden close
  button; needs an AX frame check.
- The key bar scroller showed a wide gap between `^C` and `]` after the rig's
  reveal drags (`v2-e-exit`), possibly R3-5; not measured.

## 4. Per-row verdicts

Path for every live row: G-T (WireGuard + Relay only, `path turn`), iOS 26.5.

| Row | Verdict | Measured / reason |
| --- | --- | --- |
| T-FOLLOW-01 | blocked (needs tool) | G-03 (M-ROWS) not built; compare_bottom showed the bottom rows present except while V2-1 garbles them |
| T-FOLLOW-02 | **fail** | spontaneous 1-row downward moves while following (V2-2); `r2-turn-follow60-after`: 127 reversals |
| T-FOLLOW-03 | **fail** | V2-2, frame-verified at 16.52 s |
| T-FOLLOW-04 | **fail** | wrong content in the live area (V2-1); 0 confirmed black frames |
| T-FOLLOW-05 | blocked (needs tool) | needs M-AX poll + M-ROWS |
| T-FOLLOW-06 | blocked (needs tool) | G-03; laptop load > 12 |
| T-SCROLL-01 | invalid / blocked | read holds: fps invalid; no M-ROWS |
| T-SCROLL-02 | invalid | `v2-adv-a` 1 foreign flash at 49.85 s, others 0; all invalid fps |
| T-SCROLL-03 | invalid | `v2-adv-*`: spontaneous reversals 0-87 per video per motion.py touch labels, invalid fps; not claimed either way |
| T-SCROLL-04 | blocked (needs tool) | G-04; scroll-model log stayed `reading` through streams in my runs (except the drop, V2-3) |
| T-SCROLL-05..07, 10, 11, 18 | blocked (needs tool) | S-FLING / S-SWEEP / G-03 / G-04 |
| T-SCROLL-08, 09 | invalid | Jump to bottom returned to the live bottom 3 of 3; timing not measurable |
| T-SCROLL-14 | pass-candidate (G-T only) | 0 `resize` during every scroll gesture in my window; not a gate pass (one path) |
| T-INPUT-01..05 | blocked (needs tool) | G-08, G-09 |
| T-INPUT-06 | partial | 9 composer paste + Send submissions arrived as one prompt each; 20-paste table not run |
| T-SIZE-01 | pass-candidate (G-T only) | 0 spurious resizes in my window |
| T-SIZE-02 | **fail** | 2 replays per reattach, 4 of 4 (V2-4) |
| T-SIZE-03 | **fail** | the mirror reset says 53x42 while the Mac's screen is 53x39 (V2-1 cause) |
| T-LIFE-03 | invalid | load > 12 at times; no settle tool |
| T-LIFE-04 | partial | background 10-12 s ×2: 0 replays (no reattach lines); first-frame equality not measured |
| T-LIFE-08 | pass-candidate (G-T) | 4 drops, held frame + "Reattaching…", no error text; the 2-frame black flags are unconfirmed |
| T-LIFE-09 | **fail** | V2-3 (2 of 2 reading positions lost); following resumed at the bottom |
| T-LIFE-10 | blocked (needs tool) | G-09; phone tail = Mac tail after each drop (compare_bottom), but see V2-5 |
| T-LIFE-11 | pass-candidate | Codex kept running through 4 drops (same session id at resume) |
| T-LIFE-12 | invalid | link up (Mac host answered) 2.1 s and 3.0 s after the kill, incl. the supervisor restart; no `cmux-mobile-host listening` stamp |
| T-AGENT-01 | **fail** | V2-1, V2-2 |
| T-AGENT-04 | partial | 2 of 2 (needs 10 per session) |
| T-AGENT-05 | partial | Esc 1 of 1; the ^C attempt landed after the turn ended and quit Codex (my timing, not a defect) |
| T-AGENT-06 | partial | `resume --last` 1 of 1: 0 black, 0 flashes (`v2-adv-f-resume`, invalid fps) |
| T-AGENT-07 | **fail** | V2-1 (blank/stale rows from Codex's live-area redraws) |
| T-AGENT-10 | blocked (needs tool) | G-10; spot reads: footprint 88 MB (15:52) → 118 MB (16:16) |
| T-TABS-01, 03, 04 | blocked (needs tool) | card-crop / label-band modes not built |
| T-ADV-01 | **fail** | 3 disruptive + 3 noticeable in 23 min of free play |
| T-ADV-02 | blocked (needs tool) | stream1m fixture start + G-02 replayable gesture log not wired |
| T-REG-D2 | **fail** | V2-2 |
| T-REG-D3 | pass-candidate (G-T) | red on `r1-s5` (109 black frames), green on 4 drops |
| T-REG-D4 | **fail** | V2-4 |
| T-REG-1259-*, 1337-*, 1350-* | blocked (needs tool) | G-17 red runner not built |
| All T-REND, T-SEL, T-LOAD, remaining T-INPUT/T-SIZE/T-LIFE/T-TABS/T-AGENT rows | blocked (needs tool) | their † scenarios and gaps (§11) are not built |
| T-DEV-01..11 | blocked (needs device) | no device run authorized |

## 5. Asks for the next round

1. V2-1 first: make the phone's mirror the Mac PTY's size (39 rows here), or
   prove the mirror is 39 rows and find what the grid round trip does to Codex's
   live area. Add a regression scenario: 3 grid trips during a Codex turn, then
   diff the phone's last 12 rows against the Mac's `screen read`.
2. V2-2: rerun the D7 before/after on a valid-fps recording (load < 12) with
   M-TOUCH; the after video already shows the defect.
3. V2-3: keep the reading anchor across a reattach.
4. Build G-03, G-08, G-09, G-10 and G-17; without them most rows stay blocked.
5. Run W-D and G-D; this round's live evidence is G-T only.
