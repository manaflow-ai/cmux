# Terminal QA round 4 (termqa, 2026-10-14 17:05-18:15 PT): handed off at the head of `feat-cnx-ios-termqa`

Input: qa-round-3.md and the verifier's VERIFY-round3.md (origin/feat-cnx-ios-termverify3
`712ccf3b`, verdict REJECT). Rig: simulator `cmux-mobile-termqa-1` on the laptop (laptop load
25-38 during this round, so no timing claims), `cmux-mobile-e2e-604fc689` on `mini-cmuxs-mac-mini-2`,
WireGuard + Relay (G-T). Every stimulus on the phone; the Mac CLI only observed, and
`pkill -9 cmux-mobile-host` injected link drops.

## The rig's daemon was swapped (read this before using the rig)

The rig app keeps its tag, bundle and pairing; only `Contents/Resources/bin/cmux` (the
daemon, `cmux-tui` links to it) and `cmux-tui.version` changed, then an ad hoc re-sign
and a daemon restart (terminal hosts were adopted, both e2e terminals survived).

- Running daemon: `cmux 0.1.0 (f18e13c93572…)`, branch `feat-cnx-ios-machost-d4`
  (= `origin/feat-cnx-ios-machost` 604fc689 + the four cmux-tui commits of PR #20809),
  fleet job `b7477c3d5a5c7a4496f1017a`.
- Original binary kept at `~/cmux-next-ios-e2e/termqa/stage-640c9d5f/cmux.604fc689.bak` on
  mini-2 (the staging folder name is from the first build; it now holds f18e13c9).
- iOS app on the simulator: `228b5f4e` (this branch) Demo build.
- Disk on mini-2: 3.0 GB free after the swap.

## Defects

| ID | Severity | Status | Evidence |
| --- | --- | --- | --- |
| D4 / V2-4 two replays per reattach | noticeable | **fixed, proven on the rig** | below |
| V2-5 scrollback shrinks after a drop | noticeable | **cause found; fixed for drops the phone recovers from within 30 s** | below |
| V3-1 black page for 18-60 s after a drop while reading | disruptive | **cause removed (D4), not re-verified**; restore is still not robust to a second reset | the second D4 replay was the reset that blanked the restored rows |
| New: phone reconnect after a `cmux-mobile-host` kill takes 7-70 s on G-T | noticeable | open | phone log: kills at 18:04:40 / 18:05:33 / 18:07:4x reattached at 18:04:48 / 18:05:56 / 18:08:49; nothing logged in between |
| V3-2, V3-3, V2-3 content anchoring, D5, V3-4, rotation | see VERIFY-round3.md | not started this round | |

### D4: exactly one replay per reattach (proven)

Cause, confirmed by a red test: a sized `attach-surface` of a hosted PTY returned once
the size was sent; the replay was built at the old grid, and the host's resize then
reached the phone as a `resized` replay. Red (rbx): phone 53x42 joining a 120x39 Mac
view got `vt-state` 120x39.

Fix (cmux-tui, PR https://github.com/manaflow-ai/cmux/pull/20809, base `feat-cmux-next`,
not merged): the attach re-sends the latest viewer size with a request id and waits
(at most 1 s) for the host's `ResizeAck`. The host orders the ack after the resize of
every earlier viewer size, and the daemon resolves it after applying them, so the
replay is built at the grid the phone will show. (The first version compared sizes;
the review found a 1 s stall when a direct renderer keeps another size and an ABA race
on a fast reattach; the ack barrier fixes both.)

Rig proof (`cmux-next-ios/verify/termqa/artifacts/r4-d4-proof-t1.log`, gitignored, on the laptop; the phone's
`dev.cmux.mobile:terminal` log): on t1 (Mac view 109x39, phone 53x42, grid 53x39), every
reattach after a `cmux-mobile-host` kill logged exactly one `mirror reset cause=reattach`
for surface 16 and **zero** `cause=resized-event` lines, 4 of 4 reattaches
(18:04:48, 18:05:10, 18:05:56, 18:07:07; one more at 18:08:49, also single). Before:
4 of 4 reattaches had `cause=reattach` then `cause=resized-event (rows 39…)`
(VERIFY-round2). The phone also no longer sees the PTY width change on a short drop
(next section), which removes the resize entirely.

### V2-5: cause and decision

Cause: Codex rebuilds its scrollback on every terminal width change, capped at
`[tui.terminal_resize_reflow].max_rows` (openai/codex#18575), and prints "Earlier
messages are available — press ctrl + t …" at the top. A phone link drop removed the
phone's view, so the grid widened to the Mac's own width (109 cols on the rig), and the
reattach narrowed it to 53 again: two reflows per drop, each truncating the Mac's
history. The phone's replay then carries the truncated history (phone = Mac, as the
verifier saw). Reproduced red in cmux-tui (`dropped_view_holds_the_grid…`: the grid was
120x39 838 µs after the drop).

Decision (written here as asked): **the daemon holds the grid for a departed phone or
tablet view for 30 s; it may shrink but not grow; a reattach inside that window finds
the grid it left.** Implemented in PR #20809 (`Mux::terminal_grid_target`), and the
phone now identifies its terminal channel as `device_kind: iphone`
(`set-client-info` batched with `identify`, `228b5f4e`).

Weighed against the Mac's own view:

- The Mac window keeps the phone's narrower grid for up to 30 s after the phone's link
  drops. It already shows that grid while the phone is attached; the hold only delays
  the return to its own width.
- Only handheld views hold. A Mac, TUI or desktop view that leaves never holds, so a
  Mac user closing a second Mac window sees no change in behaviour (and the existing
  test `owner_disconnect_elects_the_next_terminal_owner` still passes unchanged).
- A purposeful disconnect (`detach-client` kick, a view detach, `detach-attached-view`
  from a relay) ends every hold at once.
- A drop the phone does not recover from within 30 s still widens the grid and Codex
  reflows (rig: the 70 s reconnect above). Making that rarer needs the reconnect
  latency fixed, not a longer hold.
- An app the person backgrounds is a different path: the phone should clear its
  viewport (docs/shared-terminal-sizing.md, "Phone viewers"); that grows the grid at
  once and is not held.

Rig check: after a kill, the grid stayed 53x39 for 30 s (sampled every second) and
became 109x39 at 31 s with the phone still away; within 30 s reattaches the grid never
changed (the proof run sampled `terminal list` every 2.2 s: 53x39 throughout 4 drops). The scrollback
effect itself could not be shown on this rig: t1's Codex transcript was already capped
(967 rows, starting at "Earlier messages are available") before the round, and stayed
967 across two drops. A fresh Codex session with more than max_rows of history is
needed to show the row count holding across a drop.

## Tests this round

- cmux-tui on rbx (Linux), branch `feat-cmux-next-tui-attach-size` at `7c0126dc`:
  `cargo nextest run -p cmux-tui-core -p cmux-tui`: 5172 passed;
  `cargo clippy -p cmux-tui-core -p cmux-tui --all-targets --locked -- -D warnings`: clean.
  Red then green: `sized_attach_that_narrows_the_grid_replays_once_at_the_effective_size`
  (182021d3 red, 79687f11 green), `dropped_view_holds_the_grid_until_a_reattach_or_the_grace_ends`
  (dc66ccb6 red, 7c0126dc green). Hosted macOS cmux-tui CI not run (the PR's CI runs it).
- CmuxMobileKit on mini-cmux11s (rsync of `CmuxMobileKit/{Sources,Tests,Package.swift}` into
  `~/termqa-test/cmux-next-ios/CmuxMobileKit`): `swift test --filter 'CmuxMobileLiveTests|CmuxMobileTerminalTests|CmuxMobileTransportTests'`:
  240 tests pass. Red: `aa651fb3` (`theTerminalChannelSaysItIsAPhoneBeforeAttaching`).

## SHAs

| Repo / branch | SHA | Change |
| --- | --- | --- |
| cmux `feat-cmux-next-tui-attach-size` (PR #20809) | `182021d3`, `79687f11`, `dc66ccb6`, `7c0126dc` (+ bot autofix `264a8a04`) | D4 red/fix, V2-5 red/fix + review fixes |
| cmux `feat-cnx-ios-machost-d4` (rig daemon) | `f18e13c9` | same four commits on machost 604fc689 |
| `feat-cnx-ios-termqa` | `aa651fb3`, `228b5f4e`, this file | V2-5 phone side |

## Next (in order)

1. V3-1: re-verify after a drop while reading (D4's second reset is gone). Still make
   `TerminalReadingMark` survive a second reset (re-arm the mark on any reset that
   follows before the restore lands).
2. V3-2: output froze at item 168 after a drop mid-stream while typing still reached
   the Mac. Suspects: `heldEvents` / `inbox.setPaused(outputPaused)` left paused across
   the reattach (`DaemonTerminalSession.attach` creates a new inbox with the old
   `outputPaused`), or a pending-sequence gap. Start with a unit test that pauses
   output, drops the channel, reattaches, and expects output.
3. V3-3 and V2-3: take the reading mark from the visible rows' text whatever the scroll
   state (mid-fling too), and restore by text, not row index.
4. Reconnect latency after a drop (7-70 s): read `LinkController` backoff and the Mac
   app's `cmux-mobile-host` relaunch; a link drop that keeps hostd alive should be the common
   real-world case to measure.
5. D5, V3-4 (card controls hidden from hit-testing and accessibility; kit-owned ones to
   UPSTREAM-REQUESTS.md), rotation via XCUIDevice in an XCUITest, "unknown surface 14".
6. Then the round-3 list: V2-2/D7, timing environment (G-04 or a mini simulator),
   V2-6, D10, D1, D6, D11, D12, other paths, 60-minute agent sessions, G-14.
