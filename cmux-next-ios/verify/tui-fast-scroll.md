# TUI fast scroll: Claude Code alt mode

Branch `feat-cmux-next-ios-tui-fast-scroll`, 2026-10-23. The user asked: "find a way to make scrolling in TUI mode faster so that Claude Code alt mode works faster."

## Rig

- Phone: the Demo build in the headless simulator `cmux-tuifast` on the laptop. The base build is `49acdd1d589d`; the fix build is `6fe88e038981`. No TapKit was used.
- Mac: the hidden tagged cmux-next app `tuifast-mac` (fleet job `7e251c3d63bff287ece50361`, `3ca85ee3b2aa`) on mini-cmux11s. The path was the real link, WireGuard over TURN, with a link RTT of 13 to 15 ms.
- App: real Claude Code 2.1.309 with `CLAUDE_CODE_NO_FLICKER=1` (the fullscreen alt-screen renderer), resuming a real 400-line session (`L001 row` … `L400 row`).
- Logging: a PTY proxy between the daemon and Claude Code (`ptylog.py`) logged every byte Claude Code read, with the mini's clock (offset 8.8 ms).
- Oracle: the Mac's screen (`cmux terminal … screen read`). The rows a flick moved are the top `L###` row before minus after. The transcript has 363 rows above the first screen, so 363 means the flick reached the top.
- "model rows": Claude Code's own wheel handler (ported from the 2.1.309 bundle, `ccwheel.py`) replayed on the logged byte timeline. The transcript does not cap this number.

## What Claude Code receives

- Modes: Claude Code sets `?1049h ?1000h ?1002h ?1003h ?1006h`, so it gets SGR wheel reports `ESC[<64;x;yM` (up) and `ESC[<65;x;yM`, never arrows.
- Rows per report: Claude Code's macOS "native window" path starts at 1 row per report (`CLAUDE_CODE_SCROLL_SPEED`, default 1). Inside 40 ms it adds 0.3 per report up to 6. In a burst ("wheel mode") it decays toward a 15-row ceiling with a 150 ms half-life.
- Speed: the faster the reports arrive, the more rows each one moves.
- Keys: PgUp/PgDn and ctrl+home/ctrl+end also scroll. The wheel is the only continuous control, so the fix stays on the wheel.

## Before (base build, 3 runs each; fast flick 12 runs)

| Gesture (axe) | Reports | Rows moved | Model rows | 200 rows after first report | Stalls ≥ 0.9 s |
| --- | --- | --- | --- | --- | --- |
| Slow drag 40 pt / 0.5 s | 2 | 1 to 2 | 2 | - | 0 |
| Slow drag 200 pt / 1.5 s | 10 to 11 | 9 to 10 | 10 to 11 | - | 0 |
| Medium flick 350 pt / 0.25 s | 39 to 41 | 55 to 106 | 56 to 168 | never | 0 of 10 |
| Fast flick 500 pt / 0.12 s | 78 to 95 | 289 to 363 | 251 to 449 | 156 to 228 ms (3 s with a stall) | **3 of 12** (1015 to 1017 ms), 2 more in the first runs (1020 ms, 3047 ms) |

## Cause

1. **The phone sends a quarter of the Mac's wheel reports.** The phone sent one report per row of finger travel (1:1). The Mac app doubles precise trackpad deltas, and macOS accelerates them. Claude Code's acceleration only rises when reports come fast, so fewer reports also meant fewer rows per report. A medium flick moved about 90 rows on the phone; the same kind of flick moves about 220 on the Mac.
2. **One `send` in flight at a time stalls on any lost segment.** `DaemonTerminalSession` waited for each `send`'s reply before writing the next. With one small segment in flight, a segment lost on the TURN path waited for smoltcp's minimum retransmission timeout of 1 s (then 2 s), because no later segments produced the duplicate ACKs that trigger fast retransmit. The PTY log shows the stall: 9 batches in 124 ms, then nothing for 1017 ms, then 56 reports at once.
3. **Each wheel report was its own write.** Ghostty writes a frame's reports one at a time. Batching happened only while a request was out, so the first report of every frame paid a full request.

Not a cause:
- mobile-host and the daemon pass input through in order with no throttle. The input lane's `send` ack was 14 to 15 ms on this path.
- Ghostty's own scroll path is unchanged. It keeps the remainder of a row and writes one report per row.

## Fix

- `TerminalTUIScroll`: a drag's wheel delta is scaled by the finger's speed, like a Mac trackpad's acceleration. The gain is 1 up to 300 pt/s, so a slow drag stays line by line, and rises linearly to 3x at 3000 pt/s. The fling (`TerminalTUIMomentum`) carries the same gain and decays as before.
- `DaemonTerminalSession`: the next batch goes out once the last is written, not answered, with up to 8 unanswered.
  - Writes stay in order on one channel.
  - After a failure, the channel's other requests settle first, and every failed batch is queued again in order before newer keys.
  - A lane given up for silence never resends its batches.
  - One main-queue turn's input is one `send`.
- `DaemonClient.submit` / `reply(to:)`: write a request, then await its reply separately.

## After (fix build, same rig and gestures)

| Gesture | Reports | Rows moved | Model rows | 200 rows after first report | Stalls ≥ 0.9 s |
| --- | --- | --- | --- | --- | --- |
| Slow drag 40 pt / 0.5 s | 2 | 1 | 2 | - | 0 |
| Slow drag 200 pt / 1.5 s | 10 to 11 | 9 to 10 | 10 to 11 | - | 0 |
| Medium flick (3 + 10 runs) | 70 to 73 | 207 to 332 (median 262) | 246 to 292 | 351 to 766 ms (median 490) | 0 of 13 |
| Fast flick (3 + 12 runs) | 291 to 306 | 363 (top) every time | 1621 to 1748 | **33 to 58 ms** | **0 of 15** |

Slow drags are unchanged: two rows of finger give two reports.

## Head after the review fixes (a512eb67c48f), interleaved A/B

The three builds were installed in turn on the same rig: base, the first fix build and head, twice each. A fresh 400-line session was used. Laptop load average was 17 to 51 from other agents' work, and the simulator runs on the laptop.

| Build | Fast flick: reports | Fast flick: 200 rows after first report | Medium flick: reports | Fast flicks with a gap ≥ 0.9 s |
| --- | --- | --- | --- | --- |
| Base 49acdd1d589d | 89 to 102 | 169 to 243 ms (1.2 s and 1.9 s with a stall) | 40 to 41 | 5 of 10 |
| Fix 6fe88e038981 | 281 to 331 | 32 to 57 ms | 67 to 73 | 1 of 10 |
| Head a512eb67c48f | 284 to 319 | 36 to 57 ms | 70 to 74 | 2 of 10 |

- Rows moved for a medium flick: base 69 to 104; fix 200 to 296; head 151 to 374. Slow drags of 2 rows gave 2 reports in every build.
- Gaps under this load vary from 0.9 to 1.1 s. They come in all builds, rarely in the fixed ones.
- Two causes fit: a loss at the very end of a flick, with nothing behind it to trigger fast retransmit; and simulator hitches on the loaded laptop.
- Raising the unanswered cap above 8 could help with the first: a lost reply would then still have later replies behind it. That is a follow-up candidate, not done here.

## The Mac, same session

The cmux-next Mac app's trackpad stream was replayed into the same Claude Code PTY (`macreplay.py`). That is the stream `TerminalSurfaceView+Mouse` produces: precise deltas ×2, one report per 17 pt row (Ghostty at 2x), all of an event's reports in one write, macOS momentum decaying 0.998 per ms.

| Mac flick | Reports | Rows moved | 200 rows after first report | Settled |
| --- | --- | --- | --- | --- |
| Gentle (600 pt/s) | 25 | 44 | - | 1.5 s |
| Medium (1500 pt/s) | 57 | 178 to 218 | 668 to 674 ms | 2.0 s |
| Fast (4000 pt/s) | 144 | 363 (top); model 756 | 154 ms | 0.3 s |

- A medium flick moves about as far on the phone as on the Mac: a median of 262 rows against about 218 on the Mac, where it was about 90 before.
- A fast flick on the phone is at least as fast as on the Mac: 200 rows in 33 to 58 ms against 154 ms on the Mac, where it was 156 to 228 ms with occasional 1 to 3 s stalls before.
- The Mac stream is a replay of the app's scroll path, not a recorded trackpad. Moving the user's own trackpad would need focus on this Mac.

## Other TUIs (fix build, real link; capability matrix rows)

| Program | Slow drag (2 rows) | Flick | Result |
| --- | --- | --- | --- |
| less (arrows, 1007) | top 292 → 294 | 1 → 292 (up); stays at 1 at the top | PASS |
| vim `-u DEFAULTS`, `mouse=a` (wheel) | ruler 2908 → 2914 (2 reports, vim scrolls 3 lines each) | 2992 → 2203, 2203 → 2908 | PASS |
| htop (wheel) | selection moves; first row unchanged | first PID 96236 → 97492 | PASS |
| tmux `mouse on` (wheel) | no copy-mode marker seen (possibly before mouse on took effect) | copy mode [1475/1960] | PASS for the flick; slow-drag step inconclusive |

## Tests

These ran on mini-cmux11s in the iOS simulator (`cmux_mobile_kit-test-ios.sh`):
- CmuxMobileLiveTests: 274 tests, including the review's failure-path tests.
- CmuxMobileTerminalTests: 280 tests.
- CmuxMobileTransportTests: 5 tests.

The failing tests were committed first, in c48dac2c4673:
- `TerminalTUIScrollTests` and `TerminalTUIScrollSurfaceTests` (the byte-level check: a slow drag of 2 rows is exactly 2 SGR reports, a fast one 6) did not build without the fix.
- `inputDoesNotWaitForTheLastReply` failed with base Sources ("[1 bytes]" against three sends).
- `oneTurnsInputIsOneSend` failed with base Sources ("[10 bytes, 40 bytes]" against one 50-byte send).

## Follow-up: tail probes and 64 unanswered sends (feat-cmux-next-ios-tui-scroll-tail)

The remaining ~1 s gap had two candidate causes: a segment lost at the very end of a flick, with nothing behind it to produce duplicate ACKs; and a lost reply holding back the 8-send cap.

**Change**
- A `send` that stays unanswered for 150 ms, with no write or answer since, gets three `ping`s behind it on the same channel, twice at most per stall.
- The pings' segments, or their replies for a lost reply, bring the duplicate ACKs that retransmit the loss at once instead of after the 1 s RTO.
- Nothing typed is sent twice.
- The cap on unanswered sends rises from 8 to 64, about a second of scroll frames.

**Rig**
- The simulator moved off the laptop to mini-cmuxs-mac-mini-3 (load average 7 to 11). It is driven through an ssh shim for `axe` and `simctl`.
- The Mac stays on mini-cmux11s, the only cmux mini with a Claude Code login. The link is WireGuard over TURN.
- One idle Claude Code process (a 400-line session) ran for the whole A/B. Only the phone build changed between rounds.
- The earlier A/Bs relaunched Claude Code each round, and that typed the launch command into the running Claude Code as a prompt: Claude Code was working and streaming during those flicks. The stall counts in the A/B table above are confounded by that.

**Interleaved A/B, 3 rounds, 24 fast flicks and 9 medium flicks per build**

| Build | Fast flicks with a gap ≥ 0.9 s | Largest gap | Fast flick, 200 rows after first report | Medium flick, rows moved |
| --- | --- | --- | --- | --- |
| Merged 0d409f11765a (8 unanswered, no probe) | 2 of 24 (910, 976 ms) | 976 ms | 12 to 125 ms (median 50) | 168 to 307 |
| Tail probes 47fcd5e88b69 | **0 of 24** | 580 ms | 21 to 98 ms (median 53) | 182 to 340 |

- The probes fired 3 times in the last tail round, of 11 flicks. They are rare, and only when a send stalls.

**Re-run at the review head (501fc429fb86) on a second, quieter rig**
- Mac: the same fleet app, moved to mini-cmuxs-mac-mini-2 (load average about 3). Its Claude Code is 2.1.292 through the shared gateway.
- The move was needed because on mini-cmux11s the phone folds every rig that shares the mini's machine id into one roster entry, and other agents' rigs won it. The Mac app did not pass `CMUX_MOBILE_MACHINE_ID` on to cmux-mobile-host; since #24701 a DEBUG rig app sets `CMUX_NEXT_MOBILE_MACHINE_ID` (32 hex digits) at launch and it reaches the host.
- Simulator: still on mini-3. Path: WireGuard over TURN.

| Build | Fast flicks with a gap ≥ 0.9 s | Largest gap | 200 rows after first report |
| --- | --- | --- | --- |
| Merged 0d409f11765a | 2 of 24 (917, 934 ms) | 934 ms | 33 to 73 ms |
| Tail probes + review fixes 501fc429fb86 | **0 of 24** | 553 ms | 28 to 56 ms |

Across both rigs the merged build stalled in 4 of 48 fast flicks, and the tail-probe build in 0 of 48. Medium flicks moved 203 to 363 rows in both builds.
- The 180 to 400 ms gaps left in both builds are the fling's last, sparse wheel reports as it decays, not stalls.

**Tests**
- Red first (ab0bf320c977): `aStalledSendIsFollowedByTailProbes`, `anAnsweredSendSendsNoTailProbe` and `manyUnansweredSendsStillGoOut` do not build without `tailProbeDelay`.
- Green: CmuxMobileLiveTests (303, with the review's tests) and CmuxMobileTransportTests (5) pass on mini-cmux11s in the iOS simulator.
