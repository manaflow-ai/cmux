# Terminal QA round 5 (termqa, 2026-10-14 18:10 PT onward, in progress)

Input: qa-round-4.md and VERIFY-round3.md (origin/feat-cnx-ios-termverify3 `712ccf3b`).
Rig: simulator `cmux-mobile-termqa-1` on the laptop with this branch's Demo build (installed 19:57,
`e24da1c6`), `cmux-mobile-e2e-604fc689` on `mini-cmuxs-mac-mini-2` with the f18e13c9 daemon (round 4),
WireGuard + relay (G-T). Laptop load was 8-24 during this round, so there are no timing claims.

## Defects

| ID | Severity | Status | Evidence |
| --- | --- | --- | --- |
| Reconnect 7-70 s after a `cmux-mobile-host` kill | disruptive | **cause found and fixed (Mac app)**. Not on the rig: the rig's Mac app predates the fix | below |
| V3-2 output froze after a drop mid-stream | disruptive | **defensive fix**: the replay gate's own 2 s deadline. Not reproduced on the D4-fixed daemon | below |
| V3-3 drop during a fling loses the place | disruptive | **fixed, rig 1 of 1** | below |
| V2-3 position lost once row counts diverge | disruptive | **fixed in unit tests; rig 1 of 1** (counts 1115 -> 1118) | below |
| V3-1 black page after a second reset | disruptive | **fixed**: a second reset before the reader moves reuses the restored mark. Its trigger (the D4 double replay) is gone on the daemon | below |
| D5 never-opened card black | noticeable | **fixed, rig 1 of 1** (`c5b4b2ac`) | `round5/r5-d5-grid1s.jpg`: e2e-t2's card shows its rows 1 s after the grid opens |
| V3-4 / T-TABS-14 hidden controls in cards | noticeable | **fixed for ours, rig 2 of 2** (`f27e2c75`); kit-owned ones are in UPSTREAM-REQUESTS.md U8 | AX dump in the grid: 5 page elements exposed before, 0 after |
| "unknown surface 14" on every reattach | minor | **fixed** (red `86be059f`, green `c622a001`) | not re-checked on the rig: it needs a closed tab's session |
| Rotation rows (T-SIZE-04, rotation during a trip) | - | **not applicable on iPhone; needs a decision** | the app is portrait-only (`project.yml` `UISupportedInterfaceOrientations: [Portrait]`) |
| PR 20809 review | - | **findings fixed and posted; CI green except an outside reservation** | https://github.com/manaflow-ai/cmux/pull/20809#issuecomment-6183326812 and #issuecomment-6183852910 |
| V2-2/D7, G-04, user reports (pin, jank, Jump to bottom) | | see the section after the rig rebuild | |
| V2-6, D10, D1, D6, D11, D12, T-LIFE-08 | | not started this round | |

### Reconnect latency after a hostd kill

The phone was not the slow side. Its log shows `link macOffline` within 0.1 s of every kill, and
a dial within 0.1 s of the presence `online`; every dial succeeded at once. The Mac app's
supervisor restarted hostd late. hostd's own log (`cmux-mobile-host.log` on mini-2) shows `starting` 7,
16, 32 and 61 s after kills spaced 13-45 s apart (round 4, 18:04-18:08). `MobileHostSupervisor`
doubles its restart backoff (1 s to 60 s), and only a run that lasted 60 s reset it. A kill more than
60 s after the last one reconnected in 2.4 s (18:12:05 -> 18:12:08.3) and 1.9 s (19:59:02 -> 19:59:04.6).

Fix (cmux `feat-cnx-ios-machost`): a run that came online and stayed online for 5 s resets the backoff, so
the next restart comes after about 1 s. A run that never comes online keeps backing off.
- Red: `f59ff1b9` (`aRunThatCameOnlineRestartsAtTheFirstDelay`). It failed in MobileHostTests
  (cmux-ci step `079b59f35374f344e50111bd`).
- Green: `3df9ff77`. The CmuxNext Swift suites (4 shards, Xcode 26.6) passed 288 of 288 suites; steps `3cc5c26d…`,
  `7afad86f…`, `ff047808…` and `81e9ad07…`.
- **Rig caveat:** the rig's Mac app was built before this fix. Space `pkill` drops more than 60 s
  apart, or the restart backoff, not the phone, sets the reconnect time.

WebRTC uses the same presence path and supervisor, so the same fix applies to it.

### V2-3, V3-1, V3-3, V3-2 (phone, `e24da1c6`; red `5411a38a`)

- **V2-3: the mark matches content, with neighbours.** `TerminalReadingMark` keeps 8 rows above the
  anchor and 48 rows from it down. It tries an exact match of the anchor's rows first. If that fails,
  every distinctive row votes for where the window now sits. The red test reproduced the verifier's
  exact log line, `835 -> 935 of 1218`: one changed row among the six used to drop the match to the
  distance from the end.
- **V3-3: a reset marks the reader in any state but following.** That includes mid-fling and mid-drag,
  read from the rows on screen. The fling stops so that the restore lands.
- **V3-1: a second reset reuses the restored mark.** When a second reset arrives before the reader
  moves, it reuses the mark it just restored and does not re-read the rows on screen.
- **V3-2: the replay gate has its own 2 s deadline.** The verifier's V3-2 log (17:24:28) shows a
  reattach reset and a `resized-event` reset 24 ms apart. After the restore, the page's bottom offset
  never changed again (12696 at 17:25:55 and at 17:26:24), so the document stopped growing. Growth is
  gated only by `TerminalReplayGate`, and before this fix only the held frame's timer could expire the
  gate. That timer is not armed under a held frame or during a scroll. The double reset is gone with
  D4, and the deadline means a stuck gate ends after 2 s.
- **Tests:** CmuxMobileKit on mini-cmux11s ran `swift test --filter 'CmuxMobileTerminalTests|CmuxMobileLiveTests|CmuxMobileTransportTests'`:
  244 tests passed. Red at `5411a38a`: 5 issues in the 4 new tests.
- **Rig, read-drop (G-T, 19:59:02):** the page was settled at row 918 of 1115. After the drop:
  `reading mark restored row 918 -> 921 of 1118`. The OCR of the top 14 rows was identical before
  and after (items 116-128).
- **Rig, fling-drop (20:00:21):** a fling was started and the kill sent at the same moment. At the
  reset: `reading mark row 690 of 1118: kept`, then `restored row 690 -> 690`. The page rests on
  items 216-220, where the fling was when the reset came, not at the live bottom or the top of history.

### D5 (`c5b4b2ac`, red `cbe800df`)

The tab grid card of a tab not opened in this launch fetches its terminal's screen
(`read-screen`, which hostd's policy allows) over a short-lived `daemon` channel. The fetch
happens when the card is built, at most every 3 s, and the card shows the text in monospaced
rows. Its saved frame from an earlier launch had been a blank screen with a cursor. Once the
tab is opened, its live snapshot is used as before. Pure chooser: `TerminalCardContent`
(3 tests).

### V3-4 (`f27e2c75`)

TabsKit keeps the active page in place while the grid is open and does not lay it out again,
and SwiftUI's `accessibilityHidden` does not reach a representable's UIKit views. When the grid
opens (`prepareCard`), the page's view now gets `accessibilityElements = []`, the hidden flag,
and no user interaction; its next interactive update restores them. Rig check, 2 trips: 0 page
elements exposed in the grid, and the composer and Return come back on the page.

### Rotation

The iPhone app supports portrait only, so a rotation never happens there and T-SIZE-04 cannot be
run. Enabling landscape is a product and design decision that affects every screen. It is
listed for the user. A DEBUG geometry hook was not added, because it would be refused under a
portrait-only plist.

## While the verifier has the rig (21:10-21:55 PT): user reports and non-rig items

All on my own headless simulator `cmux-mobile-termqa-impl` (`C9E42CC5-B201-48D7-89F2-944714BADF69`, iOS 26.5,
Demo build of this branch, `-CmuxMobileTerminalDemo` mock session), never the rig. Stimulus is HID input into
the simulator with `axe` (tap, type, swipe); the in-app `stream N MS` mock command streams numbered rows.
Laptop load 6-15. Simulator display is 60 Hz.

| Item | Severity | Status | Evidence |
| --- | --- | --- | --- |
| User: "bottom not pinned to the composer, just the row above" | disruptive | **fixed** (red `6ed38fa7`, green `03866f5a`, `e5d95df0`) | `pin.sh`: gap 0.0 pt at every settle, composer 48/70/114/136 pt (1 to 6 lines), keyboard down (composer top 784/732/710/666/644/632) and keyboard up (composer top 458) |
| User: "Jump to bottom only works when scroll acceleration is 0" | disruptive | **fixed** (same red; green `03866f5a` + `e5d95df0`) | `jump.sh`: 4 of 4 taps during a fling land at the live bottom and follow (`offset 11767 -> 17524 of 17524`, `20437 -> 21844`, `26133 -> 28308`, `32102 -> 35332`); `artifacts/shots/r5-jump-sheet.png` (taps ~100/300/600 ms after the fling) shows no Jump row afterwards |
| User: scroll not smooth while an agent outputs | disruptive | **reduced; device check pending (T-DEV)** (red `342b3dd9`, green `e5d95df0`, `fc192319`) | in-app frame log below |
| G-04 in-app frame timing | tooling | **done** (`e5d95df0`) | `-CmuxMobileFrameLog`; `framesum.py` |
| V2-2/D7 one-row one-frame jump while following | disruptive | **cause found, fixed in the placement rule** (red `7deb874e`, green `fc192319`); rig re-check pending | below |
| D1, D11, D12, D6, D10, V2-6, T-LIFE-08 | | not started | |

### Bottom pin

The last row sat 8 pt above the composer card (`composerGap`), and the soft bottom scroll edge
(iOS 26) blurred that last row even at rest. Now `TerminalDocumentLayout.composerGap` is 0 and
`bottomInset(pageHeight:composerTop:)` is the one rule (`TerminalComposerPinTests`: 6 composer
positions, 3 document sizes, |gap| <= 1 pt). The bottom edge effect shows only while rows are under
the composer. `-CmuxMobileFrameLog` logs `pin: last row bottom …, composer top …, gap … pt` whenever it changes.

### Jump to bottom

`applyScroll` leaves the offset alone while UIKit decelerates, so the jump set the state and nothing
moved; then the deceleration's end (`settleScroll`) turned the state back to reading where the fling
stopped. Now `TerminalScrollModel.settled` acts only while a gesture owns the page
(`TerminalJumpToBottomTests`), and `scrollToBottom` stops the deceleration and cancels a drag in progress.

### Scroll while streaming (frame log, simulator)

`jank.sh` streams 6000 rows (`stream 6000 8`) and flings 8 times; A/B on one build with
`-CmuxMobileLegacyInteraction` (the old behaviour: 256 KB batches and full measures during a gesture).

| Run | Phase | Frames | p50 / p95 / p99 / max (ms) | Hitches (> 1.5 frames) | Main-thread work p50 / p95 (ms) |
| --- | --- | --- | --- | --- | --- |
| before | interacting + streaming | 1083 | 16.7 / 16.7 / 16.7 / 33.3 | 2 (0.2 %) | 1.23 / 2.55 |
| after (`fc192319`) | interacting + streaming | 1076 | 16.7 / 16.7 / 16.7 / 16.7 | 0 | 1.02 / 2.05 |

Per-signpost work during the drag (after): `present` 1.07 ms a frame, `scrollbar` 0.10, `output-batch`
0.01. The simulator's parse is fast and its stream light, so the batch cap barely shows here; on a
phone a 256 KB parse holds Ghostty's lock for milliseconds, and the main thread's viewport request
waits for it. `present` (the IOSurface row read that places each frame) is the remaining main-thread
cost; on a device `IOSurfaceLock` may wait on the GPU. Next step if the phone still stutters: read only
the rows near the visible band, or one sample line per row. **Device timing is pending (T-DEV):
run `-CmuxMobileFrameLog` on the phone and read `dev.cmux.mobile:frames`.**

Changes: a frame's batch is at most 16 KB while a finger or a deceleration owns the page
(`TerminalOutputQueue.budget`); during a gesture the document grows by the new rows with no row reads
under Ghostty's lock (`TerminalDocumentLayout.grown`), and is measured again at settle; one present per
Core Animation commit (below).

### G-04: in-app frame log

`-CmuxMobileFrameLog` (DEBUG and Demo builds): a display link records each frame's interval, target duration,
the page's phase (interacting, following, reading), whether output arrived in the last 100 ms, and the
screen's main-thread work per signpost (`output-batch`, `scrollbar`, `present`, `viewport-request`,
`did-scroll`). It logs a summary per gesture and every 5 s on `dev.cmux.mobile:frames`
(`TerminalFrameStats`, tested) and appends ndjson to `Documents/frame-log.ndjson`. The rig copies it
with `xcrun simctl get_app_container <udid> dev.cmux.mobile data`; `cmux-next-ios/verify/termqa/framesum.py`
summarizes it. Signposts are on `dev.cmux.mobile` / `terminal-frames` for Instruments.

### V2-2/D7

The present log of a 30 s demo follow (`-CmuxMobilePresentLog`, `artifacts/d7-present.txt`) had 31 frames
that matched no candidate. Each came as two `contents` sets about 1 ms apart in one Core Animation
transaction: the first frame is never displayed, its pixel read matched nothing, and it poisoned
the next match. With no match, the frame is placed at Ghostty's last report. The verifier's shape
(a frame one row low with the newest row gone, VERIFY-round2) is a frame Ghostty rendered for the
viewport one row older. Ghostty follows the output on its own, so no request names that viewport, it
was not a candidate, and the fallback put the older picture one row low.
`TerminalPresentMatchTests.aStaleFrameOneRowOlderStaysWhereItsRowsBelong` reproduces it (red: 900
instead of 899). Fix: shifts -1, +1, -2, +2 are always candidates (last, so they win only on a
strictly better match), and the screen handles one present per commit (a run loop observer ordered
just before Core Animation's). Same follow after: 0 unidentified frames (`d7b-present.txt`), 0
backward placements. **Rig re-check pending** (a 60 s Codex follow at 60 fps with `motion.py`).

### Tooling added

`cmux-next-ios/verify/termqa/`: `cmux_mobile_kit-test.sh FILTER` (CmuxMobileKit tests on mini-cmux11s), `killtest.py`
(hostd kill and reconnect timing on the rig Mac), `jank.sh`, `jump.sh`, `pin.sh` (simulator scenarios
with `axe`), `framesum.py`. Demo: mock `stream N MS` command, demo phase `follow`.

## Tests this round

- CmuxMobileKit on mini-cmux11s, `swift test --filter 'CmuxMobileTerminalTests|CmuxMobileLiveTests|CmuxMobileTransportTests|CmuxMobileWorkspacesTests'`:
  301 passed at `c622a001`. Note: `git archive` stamps files with the commit time, so touch
  the sources after the rsync or SwiftPM may reuse a newer build.
- CmuxNext Swift suites (cmux-ci, 4 shards, Xcode 26.6): 288 of 288 at `3df9ff77`.
- cmux-tui on rbx: clippy is clean. nextest at `e960080b` passed 5171 of 5173; the 2 failures
  were load flakes and pass alone. After the merge of `feat-cmux-next` it passed 5182 of 5183,
  with 1 flake that passes alone. The crash ratchet is ok.
- Every iOS Demo build succeeded (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, DerivedData `cmux-next-ios/build/dd`).

## SHAs

| Repo / branch | SHA | Change |
| --- | --- | --- |
| cmux `feat-cnx-ios-machost` | `f59ff1b9` red, `3df9ff77` | supervisor: a run online for 5 s restarts at the first delay |
| cmux `feat-cmux-next-tui-attach-size` (PR 20809) | `6bb49632` red, `e960080b`, `1a756bcc`, merge, `1071f4a0`, `9db5f180` | review fixes, ratchet, fmt |
| `feat-cnx-ios-termqa` (after the rig rebuild) | `6ed38fa7` red, `03866f5a`, `342b3dd9` red, `e5d95df0`, `7deb874e` red, `fc192319` | pin, Jump to bottom, smooth drag, G-04, D7. **Not on the rig simulator** (it still runs `c622a001` for the verifier) |
| `feat-cnx-ios-termqa` | `5411a38a` red, `e24da1c6`; `cbe800df` red, `c5b4b2ac`; `f27e2c75`; `86be059f` red, `c622a001` | V2-3/V3-1/V3-2/V3-3, D5, V3-4, surface 14 |

## Rig state for the next verifier (rebuilt 2026-10-14 21:00 PT)

| Part | State |
| --- | --- |
| Mac app | `cmux DEV cmux-mobile-e2e-604fc689.app` on `mini-cmuxs-mac-mini-2`, same tag, bundle id (`com.cmuxterm.app.debug.cmuxMobile.e2e.604fc689`), settings, pairing seed and Mac device id as before. Built from cmux `feat-cnx-ios-machost-d5` **`e1edf234`** (fleet job `a95fed416c5352b401c7791f`): origin/feat-cnx-ios-machost `3df9ff77` (supervisor fix) + the round-4 daemon commits + PR 20809's review fixes (`6bb49632`..`9db5f180`, cherry-picked). |
| Daemon | `cmux 0.1.0 (e1edf23408149efc15d70566bcaf590ce9273fce)`, started 20:59:43 PT. The PR-20809 files are byte-identical to the PR head `9db5f180` except base drift in `server.rs` and one comment-and-`drop(frames)` in `cmd_attach.rs` that the PR's base has. Both e2e terminals (`term_e54d808d…`, `term_c5ca5960…`) were adopted, not restarted. |
| cmux-mobile-host | the bundled one from the old app (`cmux-mobile-host.version` key `fd86929d78f0e4da`, built from `604fc689`). `cmux-next-ios/rust` is unchanged between `604fc689` and `e1edf234`, so the source key is the same. The linux-pool fleet build did not bundle cmux-mobile-host at all (see below). |
| Simulator | `cmux-mobile-termqa-1` (`C906E217-BD51-4BC7-82D8-584AB67695B7`) on the laptop, booted, headless, `feat-cnx-ios-termqa` **`c622a001`** Demo build (binary sha256 `10e5721c5f7e5fb6…`), still paired, open on `e2e-t1`. It reattached on its own after the app swap. |
| Keychain | no prompt: the rig app's auth already uses the file fallback (`keychain ADD status=-34018`, then `switching to file fallback`), and the Mac device id is a file (`cmux-mobile-host/device-id`). Settings stay in Info.plist `LSEnvironment` as before; nothing was added there. |

**Fleet gap found:** the job was routed to the linux pool (`labels cmux-next-linux`), and its app has no
`Contents/Resources/bin/cmux-mobile-host`: the Mac app's iPhone host never starts (no `mobile.cmux-mobile-host` log line).
The `604fc689` build (job `f9133c72…`, a Mac worker) bundled it. A rig build from a linux-pool job needs
cmux-mobile-host copied in (same source key) and an ad hoc re-sign.

### Rig proof after the rebuild (21:05-21:08 PT)

`cmux-next-ios/verify/termqa/killtest.py` on mini-2 kills `cmux-mobile-host` (`pkill -9`) 5 times with gaps of 20, 25, 40
and 70 s, and reads `link up` from hostd's log. The phone log is `artifacts/r5-rig-killtest-phone.log`
(gitignored, on the laptop).

| Kill | Gap | Supervisor restart (`starting`) | Link up | Phone `mirror reset cause=reattach` | `cause=resized-event` |
| --- | --- | --- | --- | --- | --- |
| 04:05:21.5Z | first | +1.3 s | +2.2 s (Direct) | 1 | 0 |
| 04:05:43.8Z | 20 s | +1.1 s | +2.0 s (Direct) | 1 | 0 |
| 04:06:10.8Z | 25 s | +1.0 s | +1.9 s (Direct) | 1 | 0 |
| 04:06:52.8Z | 40 s | +1.2 s | +4.4 s (**Relay**: the direct path did not come up, the relay took 2.2 s after signaling) | 1 | 0 |
| 04:08:07.3Z | 70 s | +1.2 s | +2.0 s (Direct) | 1 | 0 |

The supervisor restart no longer grows with kills under 60 s apart (it was 7, 16, 32, 61 s in round 4).
Exactly one replay per reattach, 5 of 5. The one 4.4 s reconnect is the WireGuard path choice (direct
failed, relay), not the restart; it belongs with V2-6.

## Next (in order)

0. PR 20809 (04:55Z): `cmux/reservation` is now success (no live reservation). One red check:
   `cmux-next daemon tests (same-tree)`, run 38678417607, `BranchAgentPresenceTests.hookToolCallsReachTheTabAndTurnEndClearsThem`
   (`timed out: reading presence`, 13 s). Failed job re-run (attempt 2) was still running at handoff:
   `~/.local/bin/glaeda-gh wait run manaflow-ai/cmux/38678417607`. If it fails again, check whether the
   attach's 1 s viewer-size barrier delays that test's attach. Do not merge.
1. After the verifier frees the rig: install this branch's head on `cmux-mobile-termqa-1` and re-check D7
   (60 s Codex follow, `motion.py` at 60 fps), the pin with Codex and Claude Code, and Jump to bottom
   on real output; then V2-6, D10, D6, T-LIFE-08, the 60-minute sessions, G-14. Non-rig: D1, D11, D12.

1. The user decides on landscape for the iPhone app: rotation rows are N/A until then.
2. V2-2/D7 (one-row jump while following), V2-6, D10, D1, D6, D11, D12, T-LIFE-08 (9-13 black
   frames on deep-history and WebRTC drops).
3. G-04 in-app frame timing (signposts and a display-link interval log), or the simulator on a
   remote Mac, so that timing rows can count.
4. ~~Rebuild the rig's Mac app~~ done (above).
