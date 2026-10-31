# Terminal and tabs: round 4 designer review

Fresh designer, 2026-10-14, against [SPEC.md](SPEC.md) and the fix lists in
REVIEW-round1..3. Build under review: `origin/feat-cnx-ios` at `ddc58d86`
(terminal round 4: `30853f29`, `303388ae`). The designer writes no app code.

**Verdict: NOT signed off.** R3-1 (pull-down with the keyboard up) is fixed in
a plain shell and after a TUI, and the relaunch handoff is now a cut. Still
failing:

- **R3-2 (major):** black frames over `top` when the keyboard moves. One hide
  was black for about 250 ms, and one show for about 230 ms.
- **R3-4 (part):** the saved relaunch frame still shows a stale cursor block.
- **R3-5:** after a swipe the key bar can settle with a **48 pt hole** in the
  middle.
- **New R4-1:** a rightward swipe that starts on the pinned keys pops the
  terminal back to Workspaces.
- **New R4-2 (minor):** Files and Links joins rows from a TUI screen into fake
  paths.

## How this was captured

- E2E rig from this worktree: Demo build of `ddc58d86`, iOS 26.5, iPhone 17
  Pro (402 × 874 pt), headless simulator `cmux-mobile-term-review4`, hidden Mac build
  `cmux-mobile-e2e-604fc689` (the same Mac build as rounds 1-3), `--keep --latency none`.
- Manual checks used the rig's `Sim`/`Mac` helpers: `axe` taps and drags, soft
  keyboard only, and no hardware key events. Mac text was written with
  `cmux terminal … write`.
- **Load warning:** the 1-minute load was 8-15 for `v1` and `v2`. It then went
  to 40-333 because another job spiked it, so it was over the limit for the key
  bar checks and `v3` (relaunch). Those two are used only for state (cut versus
  blend, settled layout), not for timing. The 1-minute samples: 10:20 = 12,
  10:21 = 15, 10:23 = 83, 10:25 = 134, 10:26 = 334, 10:27 = 181.
- I never paired with the user's Mac and used no phone.

## Rig

| Run | Steps | Result |
| --- | --- | --- |
| `100712-ios26` | fresh_install → relaunch_restore | 8/9. `last_tab_restore` FAIL is a rig fault: it looks for `suffix="e2e-t2"`, but the grid card's accessibility label is now `"e2e-t2, tab"`. Checked by hand (picked `e2e-t2`, Back, reopened: the toolbar showed `e2e-t2, ~`; switching back to `e2e-t1` works): PASS. |
| `100918-ios26` | last_tab_restore, term_direct, term_composer, shell_pull_keyboard_up, tui_quit_keyboard_up, term_keys, term_tui, term_scrollback, files_links, background | 9/10 (the same rig fault). |

Counting the manual check, all 18 distinct steps pass. Results:
`round4-review/rig-100712-results.json` and `rig-100918-results.json`.
Rig fix: match the grid card by prefix (`e2e-t2,`) or by an identifier.

## Round 3 failures, re-checked

| Item | Result | Evidence | Measurement |
| --- | --- | --- | --- |
| R3-1 plain shell, keyboard up | **PASS** | `01`, `v1` | `clear; seq 1 80` with the keyboard up, rows 59-80 visible. A 250 pt pull-down (y 150 → 400) shows 33-57; a second shows 5-29. The jump button appears; tapping it returns to the bottom. A drag from y 300 into the keyboard (y 860) dismisses it with the prompt on the composer (rows 79, 80 and the prompt sit just above the composer, with no jump button). The rig step `shell_pull_keyboard_up` agrees: row 1 after 3 pulls. |
| R3-1 after `top`, keyboard up | **PASS** | `02`, `v2` 3-16 s | After `q` + send, `❯ top` and the prompt sit just above the composer, with `HIST4142` and 27-40 above them. One pull-down shows rows 1-24. The rig `tui_quit_keyboard_up` now asserts that the content moved: PASS. |
| R3-2 no black frame, keyboard over `top` | **FAIL** | `03`, `04`, `05`, `v2` | I measured lit pixels in the terminal band on every frame at 30 fps. **Hide #1:** 29.33 → 29.57 s, the terminal is fully black apart from a cursor block (about 250 ms, 8 frames). **Show #2:** one black frame at 44.80 s, then black from 44.97 to 45.17 s (about 230 ms) until `top` repaints at 45.20 s. Hide #2 and show #1 were clean. The cause is likely the new `freezeCap` of 0.5 s: macOS `top` repaints on its own 1 s tick, so when the cap fires before the tick, the empty alternate screen shows. |
| R3-2 judgement: old rows plus black below after a hide | **Acceptable** | `05` (40.37-41.60 s) | After a clean hide, `top`'s previous frame stays at the top, and the rows below are terminal background until `top`'s next tick redraws at 41 rows (about 1.2 s here; the reported ~1.5 s depends on load). The content stays still, with nothing blank where text was and nothing jumping. This is what a real terminal shows with macOS `top`, so I accept it. A Mac-side redraw request on resize would be a nicety, not a fix. |
| R3-3 Files and Links, scrollback | **PASS** for shell output; new R4-2 | `06` | Wrapped paths written and pushed into scrollback by `seq 1 70` (`/private/tmp/cmux-mobile-r4-wrapped-sample.md` split at column 48, and `/tmp/cmux-mobile-r4-second-file.txt`) are listed whole: `/tmp/cmux-mobile-r4-wrapped-sample.md` once, `/tmp/cmux-mobile-r4-second-file.txt` once. There are no `rivate/…` or `…txt` tails. **R4-2:** two fake entries came from `top`'s screen, where my command text was echoed on `top`'s `mode [n]:` line: `/private/tmp/cmux-mobile-r4-wrappePID` (a full-width TUI row joined to the next row, `PID …`) and `s/private/tmp/cmux-mobile-r4`. |
| R3-4 relaunch handoff | **Cut PASS; cursor FAIL** | `08`, `09`, `v3` | Saved frame (dimmed, "Connecting to Aziz's MacBook Pro…") from 1.90 s. The live frame replaces it in one frame, 2.43 → 2.47 s, with no overlapping text (`09`). The saved frame still has a **light cursor block at column 0 by rows 3-4** (`09`, first panel), so the round 3 request to drop it is not met. Minor: at 2.50 s one frame of the live screen lacks the last rows (WHILECLOSED1-4 and the prompt), and they are back at 2.53 s. |
| R3-5 key bar after a swipe | **FAIL** | `07` | At rest: tab 165.3, ⇧tab 216, ↑ 276-316 pt, then the joystick at 322 (6 pt gaps). **PASS.** After swiping to the end, the bar settled with `-` at 165.3-205.3 and `paste` at 253.3-316, a **48 pt hole** between them (`07`, top). The swipe was taken at load ~100, but the frame was the same after 2.5 s. In another settled state the gaps were spread evenly: `]` 205.3 → `^R` 220.7 → `^B` 276, so **15.4 pt** gaps against 6 pt at rest (`07`, bottom). There is no end hole, but the spacing visibly differs from the rest state. |
| R1-0 relaunch restore | **PASS** | rig `relaunch_restore` | Restored in 1.5 s with no connecting label; attached at 3.3 s. "The Mac ran input 13.5 s after launch" was measured at load 40, so I don't use it as a timing. |

## New findings

- **R4-1 (major): swipe-back from the key bar.** With the keyboard up, a
  rightward swipe that starts on the pinned keys (`^C`, x 140 → 330, y 536)
  pops the terminal back to the Workspaces list (`10`). The same swipe
  starting inside the scroller at rest does not (checked: the composer was
  still there). It first happened during the key bar checks. The full-width
  back gesture should not start on the key bar.
- **R4-2 (minor):** see R3-3. Files and Links should join rows only when the
  terminal marked them soft-wrapped. A full-width row on a TUI screen is not
  a wrap.
- **R4-3 (accessibility, minor):** a zoomed tab's hidden close button
  (`Close e2e-t2` at 372,0) stays in the accessibility tree over the terminal.
  The tab grid thumbnails expose their live terminal controls (composer,
  Return, "Scroll to bottom", scroll bars) to VoiceOver.

## Onboarding "Connect your Mac": Continue tap investigation

Evidence: 15 rig runs in this worktree and in `feat-cnx-ios-e2erig`. 4 failed
at `choose_space` with "never reached the tab bar": `043930`, `051334`,
`075014`, `094540`. All 4 used the earlier rig, which tapped Continue once,
the moment `connect-mac.status` existed. Today's run (`100712`, with a retry
loop) advanced on the first tap.

- **The state was ready.** The failure screenshot (`11`, `094540`) shows the
  page settled with "Aziz's MacBook Pro is online" and Continue visible, so
  the button existed and was enabled. `PairMacStep` shows `PrimaryCapsule`
  only when `onlineMac != nil` and never disables it. Its only hit gate is
  `.allowsHitTesting(!isLoading)`, and `isLoading` is always false here. A
  later tap by hand worked, which rules out a persistent dead button or a
  wrong state.
- **Likely cause: rig timing.** The Mac is already online when the page
  pushes, so the status line reads "online" from the first frame. The rig
  waited for the status element and then tapped at once, while the
  NavigationStack push was still animating. UIKit drops touches during a
  navigation transition, and accessibility already reports the incoming
  page's frames.
- **Real app issue found on the way (visual, not the cause):** in `11`, the
  Continue capsule's lower edge is covered by the account footer
  ("Signed in as … · Sign out"). The capsule runs to about 815 pt, and the
  footer's opaque background starts at about 804 pt. SetupPage promises the
  actions 24 pt above the footer. The capsule's center (about 790 pt) is
  above the footer, so a center tap still lands. It does not explain the
  dropped taps, but a tap on the lower part of the visible button would hit
  the footer.
- **Recommendation:** keep the rig's retry. Better, wait until the Continue
  frame is the same on two polls (the push has finished) before tapping. For
  the app, fix the footer overlap so the actions sit 24 pt above the footer.
  This can be checked at 402 × 874 with a long email. No change is needed to
  the button's enabled state.

## Fix list (round 5)

1. **R3-2:** no black frame over a TUI. Keep the held frame until the
   alternate screen has content. A 0.5 s cap is shorter than macOS `top`'s
   1 s repaint. Raise the cap to at least 1.2 s, or keep holding while the
   alternate screen is blank. Check `v2`-style: two hides and two shows over
   `top`, with no frame where the terminal band is all black.
2. **R4-1:** a horizontal swipe that starts on the key bar (pinned keys
   included) must not trigger swipe-back.
3. **R3-5:** after a swipe, the gaps between keys stay at about 6 pt. No
   interior hole (48 pt seen), and no spread to 15 pt. Snap the scroller to a
   key boundary instead, or keep the leftover at the trailing end only when it
   is under one gap.
4. **R3-4:** drop the cursor block from the saved relaunch frame. Avoid the
   one frame where the live screen lacks its last rows.
5. **R4-2:** join rows only when the terminal marks them soft-wrapped.
6. **R4-3:** hide the zoomed card's close button and the thumbnails' live
   controls from accessibility.
7. **Onboarding:** fix the footer overlapping Continue. Rig: wait for a stable
   frame before tapping, and match grid cards by prefix.
8. Upstream, unchanged: U1-U5. Pending user decision, not decided here:
   CmuxTabsKit's ~240 ms zoom.

## Not verified

- R2-2 paste of a file (simulator pasteboard); hardware keyboard; 120 Hz.
- Timings in `v3` and the key bar checks were taken at load over 40 (state
  only).

## Artifacts (`round4-review/`)

- `01-shell-kbup-pull-and-dismiss.jpg`, `v1-shell-pull.mp4`: R3-1 in a plain
  shell.
- `02-top-quit-kbup-then-pull.jpg`: R3-1 after `top`.
- `03-top-kb-hide1-black-29.33-29.57s.jpg`,
  `04-top-kb-show2-black-44.97-45.17s.jpg`,
  `05-top-kb-hide2-held-then-top-refresh.jpg`, `v2-top.mp4`: R3-2.
- `06-files-and-links-scrollback-and-tui-fragments.jpg`: R3-3, R4-2.
- `07-keybar-after-swipes-hole-and-spread.jpg`: R3-5.
- `08-relaunch-strip-1.9-7.0s.jpg`, `09-relaunch-cut-2.43-2.53s-zoom.jpg`,
  `v3-relaunch.mp4`: R3-4.
- `10-swipe-right-from-pinned-keys-pops-terminal.jpg`: R4-1.
- `11-onboarding-connect-mac-stuck-094540.jpg`: onboarding.
- `rig-100712-results.json`, `rig-100918-results.json`.
