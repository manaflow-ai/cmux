# termqa analyzers and fixtures

Tools for the measures in `../design/terminal/ACCEPTANCE.md` section 2 (M-MOTION,
M-BLACK, M-TOUCH, M-ROWS; gaps G-02 and G-03). They read simulator recordings
(`simctl io recordVideo`, 1206 x 2622 px, variable frame rate). Coordinates are points
in the 402 x 874 screen (3 px per pt). They need `ffmpeg`/`ffprobe`, numpy and PIL.

## motion.py (M-MOTION, M-BLACK, M-TOUCH)

```
python3 motion.py VIDEO [--fps 60] [--start S] [--dur D] [--top 70] [--bottom 0.55]
                        [--crop x,y,w,h] [--width 402] [--json OUT] [--quiet]
                        [--touch LOG --video-start EPOCH]
```

- Band: `--top` pt to `--bottom` x 874 pt, or `--crop x,y,w,h` in pt (a grid card,
  a tab-label band). `--width 1206` analyses at full resolution (1 px precision).
- Resamples to `--fps` (60 by default). Flashes last at most about 33 ms (1 frame at
  30 fps, 2 at 60). At 60 fps it finds one-frame jumps that 30 fps skips (see below).
- `--touch`: json lines `{"t": host_epoch_s, "kind": "drag|tap|swipe|key", "dur": s}`
  (`t_end` instead of `dur` also works; default durations: tap/key 0.1, swipe 0.3,
  drag 0.5). A move is finger-driven inside `[t, t + dur + 0.6 s]`, else spontaneous.
- Output json: `{"summary": ..., "frames": [...]}`.
  - Each frame: `t`, `lit` (fraction of band pixels with luma > 60), `shift_pt`,
    `shift_px` (video px), `shift_rows`, `resid`, `resid0` (zero-shift residual), `conf`
    (1 - residual / best residual more than half a row away; low = periodic text),
    `move`, `finger` (with `--touch`), `black`, and `flash` `{frames, kind: jump|foreign,
    jump_pt, diff_prev, prev_to_next}`.
  - Summary: `row_pitch_pt`/`row_pitch_px` (autocorrelation of the band's row profile),
    `moves`, `moves_down`, `moves_up`, `max_move_rows`, `reversals` and
    `reversal_list` (opposite moves within 0.5 s), `flashes`, `flashes_jump`,
    `flashes_foreign`, `flash_list`, `lit_median`, `black_frames`, `black_runs`,
    `black_times`, `source` (`effective_fps`, `frac_gaps_over_34ms`, `max_gap_ms`,
    `valid`), `valid`. With `--touch`: `finger_moves`, `spontaneous_moves`,
    `spontaneous_moves_down`, `spontaneous_moves_list`, `spontaneous_reversals`.
- Shift search: when two local minima of the residual tie within 5 %, the smaller
  `|shift|` wins, so periodic text does not produce false reversals.
- Black: `lit` < 0.4 % while the run's median `lit` is at least 1.6 %.
- Validity: section 1.4 requires fewer than 2 % of source frame gaps over 34 ms. The
  simulator records only when the screen changes, so idle stretches count as gaps.
  Pass a `--start/--dur` window around the activity.

Validation (2026-10-14):

| Recording | Args | Result |
| --- | --- | --- |
| r2-turn-follow60-before | `--start 2 --bottom 0.8 --fps 30` | 3 flashes (7.07, 22.00, 57.77 s), all one-row jumps |
| r2-turn-follow60-after | same | 0 flashes |
| r2-turn-follow60-before | same at 60 fps | 14 one-frame jumps |
| r2-turn-follow60-after | same at 60 fps | 9 one-frame jumps (16.5 s checked by eye: the page is one row lower for one 13 ms source frame) |
| r1-s5-link-drop-mid-stream | defaults | 1 black run, 5.18-6.98 s (109 frames; `[unknown surface 10]` on black) |

Row pitch is calibrated at 16.0 pt (48 px). Every sample window is `INVALID` by the
34 ms gap rule: 17-38 % of source gaps exceed 34 ms.

## rows.py (M-ROWS)

```
python3 rows.py VIDEO [--fps 10] [--start S] [--dur D] [--top 50] [--bottom 760]
                      [--left 0] [--width 402] [--row-pt 16] [--drift-px 1]
                      [--pattern REGEX] [--jobs 2] [--video-start EPOCH] [--json OUT] [--quiet]
```

- It crops the band at full resolution and reads the frames with Vision through
  `~/cmux-next-ios-e2e/bin/ocr-batch`. The binary is built from `../e2e/ocr_batch.swift`
  with `xcrun swiftc -O` when it is missing or stale. One process reads every frame.
  The fast recognition level reads `#0000112` reliably. The accurate level garbles the
  last digit and is slower (`--accurate`). The run takes about 20 ms per frame: 60 s
  at 10 fps (614 frames) takes 12 s.
- Ids: `#%07d`, with an optional 13-digit send time after the id (`--pattern` swaps
  the regex; group 1 is the id).
- Each frame in the json has `t`, `n`, `window` [min, max], `ids` {id: y_pt},
  `breaks` (adjacent ids whose step disagrees with their y distance), `dy_pt` (median y
  change of the ids shared with the previous frame), `same_window` (|dy| < half a
  row), `drift` (same window and |dy| > `--drift-px`), `bounce`/`backstep`, `foreign`
  (`disjoint`: the window shares no id with either neighbour while the neighbours
  overlap; `break`: an internal contiguity break), and `pos`.
- Summary: `id_min`, `id_max`, `first_window`, `last_window`, `foreign_frames`,
  `backsteps` (content moves down at least half a row and straight back up the next
  frame), `bounces` (either direction), `same_window_pairs`, `drift_frames`,
  `max_read_drift_px`, `rows_seen`, `id_pitch_pt`. With `--video-start` and stamped
  rows, `lag_s` {n, p50, p95, max} (the first frame that shows a newest row, minus its
  send time).
- `rows_selftest.py` renders a synthetic recording with PIL and checks that the
  tracker finds exactly one foreign frame, one backstep and one drift step (PASS).
- On r2-turn-follow60-before (`--start 2 --fps 30 --bottom 690 --pattern
  '^(\d{1,4})\.'`, Codex's numbered list) it reports backsteps at 7.07 and 57.77 s
  and a bounce at 22.0 s. These are the three motion.py flashes. It finds 0 foreign
  frames and 0 read drift over 1080 same-window pairs.

## fixtures/ (section 10.1)

These need only Python 3 (macOS system python3) and the standard library. Stage the
whole directory on the Mac mini, because each script imports `_rows.py`. Start them
by typing on the phone. `-h` prints a one-line usage. Rows are
`#%07d [<send-epoch-ms>] <text>`, with the id in column 0 and SGR colour on the text.

| Script | Content |
| --- | --- |
| `stream20.py [SECONDS=300] [RATE=20]` | Stamped rows at RATE per second, with a 2-line live area redrawn below (cursor up, erase), then `STREAM20-END rows=N` |
| `stream1m.py [SECONDS=600] [BITS=1000000]` | Token-bucket paced, stamped, 70-column coloured rows, with a status line redrawn below, then `STREAM1M-END` |
| `hist.py N` | Exactly N rows, #0000001 to N |
| `ids.py [N=2000000]` | `#%07d y` rows as fast as possible (2M rows in 0.4 s), then `IDS-END N` |
| `crcgen.py N` | `#%07d <text> crc=%08x` rows, then `TOTAL N <crc32 of all rows>` |
| `line1m.py [BYTES=1048576]` | One line with no newline, then `#0000001 LINE1M-END bytes=N` |
| `altflip.py [SECONDS=60] [HZ=20]` | Enters and leaves the alternate screen HZ times per second, drawing frame rows `#%07d` (frame x 100 + row), then `ALTFLIP-END cycles=N` on the main screen |
