# Terminal and tabs: round 3 designer review

Fresh designer, 2026-10-14, against [SPEC.md](SPEC.md) and the fix lists in
[REVIEW-round1.md](REVIEW-round1.md) and [REVIEW-round2.md](REVIEW-round2.md).
Build under review: `origin/feat-cnx-ios` at `6187529c` (terminal round 3:
`c5f1aa8e`, `1e0ef84a`, `bb3f60e6`). The designer writes no app code. Every
item was re-checked with this review's own captures; the implementer's notes
and the rig's own pass were not taken as evidence on their own.

**Verdict: NOT signed off.** The R2-1 layout is fixed: after quitting `top`
with the keyboard up, the shell gets its 41 rows back and the earlier output
sits above the prompt. R2-2, R2-6 and the R2-3 hide case also pass. Four
problems remain:

- **R3-1 (major).** With the keyboard up and the terminal at the bottom, a
  pull-down above the keyboard does nothing, so history can't be reached. The
  same thing happens in a plain shell, not only after a TUI. Round 2's check
  for R2-1 was "a pull-down scrolls", so R2-1 is not closed.
- **R3-2.** Showing the keyboard over `top` now gives about 150 ms of black.
- **R3-3.** Files and Links still lists pieces of wrapped paths.
- **R3-4.** On relaunch the saved frame and the live frame are blended, so you
  see two sets of text overlapping.

## How this was captured

- **Live.** E2E rig from this worktree: Demo build of `6187529c` + this review
  commit, iOS 26.5, iPhone 17 Pro (402 × 874 pt). Headless simulator
  `cmux-mobile-term-review3b`. Hidden cmux-next DEBUG Mac build `cmux-mobile-e2e-604fc689`
  (the same build as rounds 1 and 2). Two runs, both started from
  `fresh_install` and using `--keep --latency none`. `091552-ios26` covered
  fresh_install to relaunch_restore: **9/9 pass**. `091909-ios26` covered
  term_direct, term_composer, tui_quit_keyboard_up (new), term_keys, term_tui,
  term_scrollback, files_links and background: **8/8 pass**. Results are in
  `round3-review/rig-*-results.json`.
- **Manual checks.** Run afterwards on the same session with the rig's own
  `Sim`/`Mac` helpers (`axe` taps and drags), typing only on the soft keyboard,
  with no hardware key events. PTY size and screen were read on the Mac with
  `cmux terminal list` and `terminal … screen read` against the rig socket.
- **Mock.** The same Demo app relaunched with `-cmuxMobile.dev.mockData YES`
  ("mock (layout only)").
- **Load.** 1-minute load averages for the recordings: 6.0 (`v1`), 7.2 (`v3`),
  29.6 (`v5`) and 44 (`v4`, key bar swipe: another job spiked it). `v4` is used
  only for when motion stops, not for timing. Every other recording was under
  40.
- **Units.** Measurements are in pt: 1206 px frames ÷ 3, or `axe` frames.
  Videos are scaled to 402 px.
- Never paired with the user's Mac; no phone. At the end the simulator was
  deleted and the rig Mac app and its helpers were quit.

## Round 2 failures, re-checked

| Item | Result | Evidence | Measurement |
| --- | --- | --- | --- |
| R2-1 quit `top` with the keyboard up | **Layout PASS, scrolling FAIL (R3-1)** | `01`, `02`, `v1`, `v2`, rig `tui-quit-kbup` | Setup: `clear; seq 1 30; echo HIST3132`, then `top` from the composer. With the keyboard up the PTY was 53 × 24. After `q` + send it was **53 × 41** on the Mac, with the cursor on row 39. On the phone the prompt sits just above the composer, and `16`…`30`, `HIST3132` and `❯ top` are above it (`01`, second frame). There is no band of black and no rows above the top inset other than the screen's own rows 1-15. A 250 pt pull-down from y 200 → 450 does not move the content (`01`, third frame; `v1` 16-19 s): the scroll indicator flashes and the rows stay put. A push-up does scroll. With the keyboard down everything is reachable (`01`, last frame). The rig step passes because it clears first and only checks that its marker is still on screen after the drag. It does not check that the drag moved anything. |
| R2-2 Paste of a copied file | **PASS (code + unit tests)** | `ComposerPasteRoute.swift`, `TerminalComposer.swift:160-178`, `ComposerPasteRouteTests.swift` | A `public.file-url` or a `file://` string routes to `.file(url)` and then `loadFiles([url])`, the same path Files uses. That path handles security-scoped access, the size cap and the upload on send. If the file can't be read the user sees "Couldn't read X.". A phone `file://` path is never typed into the shell, and a malformed one is dropped. Paste is offered only for an image or a file. The 5 tests cover image first, file URL, `file://` as text, text and web links, and when Paste is offered. Not driven live: the simulator pasteboard can't hold a file. I did not run the tests; CI owns them. Gap, not a fail: a copy from Files that carries only the file data (no file URL) does not offer Paste. |
| R2-3 no black frame on keyboard hide | **Hide PASS; show FAIL (R3-2)** | `03`, `04`, `v3` | Hide over `top` (`v3` 1.5-2.7 s, every frame): the alternate screen stays pinned to the composer while it falls, and redraws at 41 rows at 2.60 s. No black frame. Show (tap on the terminal at 6.2 s): from **7.048 to 7.198 s (~150 ms)** the terminal is black except for the cursor block (`04`, frames 6-10). Then `top` redraws at 24 rows. In round 2 the show direction had no blank frame, so this is a regression in the new hold-the-last-frame code (it lets go after one batch, before `top` redraws). |
| R2-4 key bar at rest, trailing gap | **PASS** (polish R3-5) | `05`, `v4` | At rest: `tab` 165.3, `⇧tab` 215.3, `↑` 274.7-314.7 pt, all whole and at full brightness, with no fade at rest. The trailing gap is ↑ end → joystick (323 pt) = **6.3 pt**, the same as the gap between keys. Good. After a swipe the bar settles in about 1.0 s with whole keys and no sliver (round 2 had 13 pt). But the leftover space becomes one hole of **19-20 pt**: leading (`]` starts at 184 pt, 25 pt after `^C`) or trailing (`]` ends at 297 pt, 26 pt before the joystick). Frames taken 1.5 s after a swipe at load 44 were still moving, so judge only the settled frames. |
| R2-5 relaunch frame handoff | **Saved frame PASS; handoff FAIL (R3-4)**; pill = U5 | `08`, `09`, `v5` | Setup: cold terminate while the tab shows `seq 1 40; echo BEFOREQUIT`, `echo WHILECLOSED` run on the Mac while the app is closed, then relaunch. The launch screen is white until 3.9 s. The saved frame is shown dimmed with "Connecting to Aziz's MacBook Pro…" from 4.0 s, and it is the frame from quit time (1-40, BEFOREQUIT). That is fixed. Live rows arrive at about 4.65 s, 4 rows lower because of the new output. During the 120 ms fade-out both texts are drawn (`08`: `3/7`, `10/14` overlap at 4.65-4.75 s). The saved frame also shows a light cursor block in column 0 near row 3. Title pill: light (luma 117-175) from 4.00 to 4.53 s, then dark (34). This is documented as upstream **U5** in [UPSTREAM-REQUESTS.md](UPSTREAM-REQUESTS.md) and is not failed here. |
| R2-6 composer-edge fade | **PASS** | `06` | At the bottom at rest, the prompt row just above the composer is at full brightness (max 230), with no fade. When scrolled up, row `184` straddling the fade goes 170 → 90 across 715-724 pt, and the composer card starts at 740. The fade is drawn only while rows are under the card (`updateBottomFade`). |
| R2-7 Files and Links | **FAIL (R3-3)**; dedupe and chip spacing PASS | `07`, rig `07-files_links` | The `ls -l` path wrapped `/tm` + `p/…sample.md` on screen is listed once as `/tmp/cmux-mobile-e2e-091910-sample.md`. `/private/tmp/…` and `/tmp/…` collapse to one entry. The Done button ends at 468.8 and the chips start at 477.4 (**8.6 pt**; spec 8). But the list ("All 8") still has two fragments: **`rivate/tmp/cmux-mobile-e2e-091910-sample.md`** and **`1910.txt`** (the tail of `/tmp/cmux-mobile-e2e-091910.txt` wrapped by vim/`ls` earlier in this session's scrollback). The new rule only drops a piece whose whole path is on screen *now*. Pieces in scrollback whose whole path has scrolled off are still listed. |

## Other SPEC items, spot-checked this round

| Item | Result | Evidence |
| --- | --- | --- |
| B1 top-anchored | PASS | rig `term_scrollback` ("after clear the first row is at y 65 pt"), `rig-scroll-b1-top`. |
| B2 pinned esc / ctrl / ^C | PASS | `05`, AX: esc 10-54, ctrl 60-113.3, ^C 119.3-159.3, at rest and after swipes. |
| M3 last row above the composer | PASS | `06`, `01`. |
| M4 one key bar rule, mock = live | PASS (soft keyboard) | `10`: mock key bar frames are identical to live, there is no bar at rest, and the mock composer has `+`. |
| M6 drag-dismiss pins the prompt | PASS as written; it causes R3-1 | `TerminalViewController.scrollViewDidScroll`: `dragPinsToComposer` holds the offset for any downward drag that starts while following with the keyboard up. A drag that ends above the keyboard never moves the keyboard, so the gesture does nothing. |
| M7 refused preview | PASS | rig `files-preview` (`artifacts.preview.refused`). |
| M8 hidden controls | FAIL, deferred upstream (U3) | AX: `Page Menu` (90, 792) and `Reload` (268, 792) are still in the toolbar. |
| P5 return from background | PASS | rig `background`: Connected 8.5 s after foreground (load 17-21), input reached the Mac. |
| P6 grid active ring | FAIL, deferred upstream (U1) | unchanged. |
| R1-0 relaunch restore | PASS | rig: restored in 1.5 s, attached 2.9 s. "Mac ran input 13.3 s after launch" (round 2: 3.6 s) ran at load ~18; not used as a timing. |
| Pending, not decided | — | CmuxTabsKit's ~240 ms grid zoom (user decision). |

## Fix list (round 4)

- **R3-1 (major) Pull-down with the keyboard up must reach history.** Today
  `dragPinsToComposer` freezes the offset for the whole drag. Pin the content
  only while the keyboard is actually following the finger (the touch has
  crossed the keyboard's top). Until then, a downward drag scrolls normally,
  as in Messages. Keep M6's promise for the part of the gesture that moves the
  keyboard. Check: keyboard up at the prompt, `seq 1 80`, a 250 pt pull-down
  from y 150 shows earlier rows; a drag into the keyboard still dismisses it
  with the prompt on the composer. Also make the rig's `tui_quit_keyboard_up`
  assert that the drag moved the content (for example, that a row above the
  first visible one becomes visible).
- **R3-2 No black frame on keyboard show over a TUI.** `freezeLastFrame` lets
  go after the second batch following `ESC c`. On the shrink to 24 rows the
  replay is an empty alternate screen, so ~150 ms of black shows until `top`
  repaints. Hold the frame until the alternate screen has drawn non-blank
  content again (or the cursor moved off home), with a cap of about 500 ms.
- **R3-3 Files and Links: no wrapped fragments from scrollback.** Join
  soft-wrapped rows across the whole scanned range (scrollback included) before
  detecting paths, rather than removing pieces only when the whole path is on
  screen. Check: `rivate/tmp/…` and `1910.txt` in `07` must not appear.
- **R3-4 Relaunch handoff: swap, don't blend.** When live rows replace the
  saved frame, hide the saved frame in one frame. Don't fade it out over the
  live text if the layouts differ. Also drop the cursor block from the saved
  frame.
- **R3-5 (polish) Key bar after a swipe.** The settled scroller leaves a single
  19-20 pt hole at one end. Either spread the leftover evenly across the
  visible keys' spacing, or snap so the hole is never more than the 6 pt gap
  between keys.
- **Upstream (unchanged):** U1 active tab ring, U2 card title, U3 hidden Page
  Menu and Reload, U4 thumbnail hook, U5 title pill flash. Pending user
  decision, not decided here: CmuxTabsKit's ~240 ms zoom.

## Not verified

- A real file URL on the pasteboard, and image paste end to end (simulator
  pasteboard limits). R2-2 is judged from the code and unit tests.
- Hardware keyboard key bar; ctrl double-tap lock; 120 Hz.

## Artifacts (`round3-review/`)

- `01-r21-top-quit-kbup-strip.jpg`: `top` with the keyboard up, after `q`,
  after a pull-down, after a push-up, keyboard down. `v1-r21-quit-top-kbup.mp4`.
- `02-kbup-at-bottom-pull-does-not-scroll.jpg`, `v2-kbup-at-bottom-pull.mp4`:
  R3-1 in a plain shell.
- `03-top-keyboard-hide-frames-1.5-2.7s.jpg`,
  `04-top-keyboard-show-black-frames-6.98-7.28s.jpg`,
  `v3-top-keyboard-hide-show.mp4`: R2-3, R3-2.
- `05-keybar-rest-and-settled-after-swipes-x150-350pt.jpg`,
  `v4-keybar-swipe.mp4`: R2-4, R3-5.
- `06-bottom-fade-at-bottom-vs-scrolled-up.png`: R2-6.
- `07-files-and-links-fragments.jpg`: R2-7, R3-3 (terminal, list, full list).
- `08-relaunch-handoff-4.55-4.85s-blend.jpg`,
  `09-relaunch-strip-2.6-6.6s-8fps.jpg`, `v5-relaunch.mp4`: R2-5, R3-4.
- `10-mock-layout-only-rest-and-keyboard.jpg`: mock (layout only).
- `rig-091552-results.json`, `rig-091909-results.json` and `rig-*.jpg`: the
  rig runs.
