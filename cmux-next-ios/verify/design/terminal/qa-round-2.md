# Terminal QA round 2 (termqa, 2026-10-14 15:00-15:50 PT)

Rig as round 1 (`qa-round-1.md`): simulator `cmux-mobile-termqa-1` (iOS 26.5) on the laptop,
real tagged Mac app `cmux-mobile-e2e-604fc689` on `mini-cmuxs-mac-mini-2`, real Codex CLI,
every stimulus typed or pasted on the phone. New this round: **WebRTC TURN** (Relay
only) and **WireGuard TURN** (WireGuard + Relay only) paths, the merged integration
branch (`origin/feat-cnx-ios` 981d2d57 + CmuxTabsKit 5aa0c998), and ACCEPTANCE.md
(merged d59fbbfb) as the gate. Builds under test: `ae5cf4e7` (fix check), then
`6d6f7f32` (integrated + D8/D9 fixes + G-07).

Load: 6-25 (1-minute) during this round; several recordings have an effective
source fps under 30 (motion.py marks them INVALID). Timing rows are not claimed.

## Defects and fixes

| ID | Severity | ACCEPTANCE row | Summary | Status |
| --- | --- | --- | --- | --- |
| D2 | disruptive | T-FOLLOW-02, T-REG-D2 | 7-row jump while following Codex | fixed `d3142620`; 75 s W-D follow: 0 jumps > 1 row |
| D3 | disruptive | T-LIFE-08, T-REG-D3 | blank + `[unknown surface 10]` on a link drop | fixed `d3142620`; W-D drops idle and mid-stream: 0 blank, 0 error text |
| D7 | disruptive | T-FOLLOW-03 | **One-frame 1-2 row jump while following a stream**: the offset moved on the scrollback report one transaction before Ghostty presented the frame with the new rows. W-T, 60 s Codex follow: 3 flashes, 5 down moves, 35 reversals | **reduced, not fixed** `ae5cf4e7` (the follow offset moves in `surfacePresented`). At 30 fps: 3 → 0 flashes. Re-analysed at 60 fps (motion.py G-02): 14 → 9 one-frame jumps per 60 s; the remaining ones show the page one row (16 pt) lower for a single ~13 ms frame (after video, 16.5 s). Still open. |
| D8 | disruptive | T-SIZE-02, T-LIFE-09/10 | G-T: after background or a drop, the phone replayed Codex's whole transcript visibly and garbled (a stuck row over the live area), 80 items behind the Mac. Cause: the Mac's own window owns the grid (39 rows); the phone's attach asked 42; the PTY went 42 → 39 and Codex redrew its transcript on each SIGWINCH | **partly fixed `6d6f7f32`**: a reattach after an overruled size attaches at the Mac's size (log `reattach at the Mac's 53x39`); the daemon still sends one `resized` event after the reattach (D4 remains). After background: phone 501 vs Mac 512 (≈0.6 s, sampling skew); after a drop: 900 = 900 |
| D9 | noticeable | T-SIZE-01/03 | Opening a tab from the grid measured 42, 44, 43, 42 rows during the zoom; the attach carried 44, the settled 42 followed: 2 resets per open | **fixed `6d6f7f32`** (settle applies before the attach); open now logs `resize 53x42 cause=first` then one `mirror reset cause=attach size=53x42` |
| D4 | noticeable | T-SIZE-02 | Every reattach still gets a `resized` event (rows 39) right after the attach, so 2 replays per reattach. Daemon-side (sizing reducer / retained report). | open: Mac side |
| D10 | noticeable | T-LIFE-03, T-FOLLOW-06 | G-T: after a grid round trip (t1 → t2 for 6 s → t1) while Codex streams, t1 shows the stream ~1 s behind the Mac for at least 10 s (phone item − Mac item = −9..−14 at 1.1 s samples; steady state without the switch: +2..+4 with the same sampling order). | open, investigating (renderer pacing after re-show?) |
| D11 | polish | T-LIFE-06 | A relaunch after a kill without backgrounding (simctl terminate) shows no saved frame: 0.6 s black with only the Connecting pill. With a background first (the normal path) the dimmed saved frame shows. | open |
| D12 | polish | T-LIFE-06 | White launch screen (~0.8 s, system light appearance) before the dark terminal on a restored terminal tab (codex-qa F11). Design decision (launch screen follows the system appearance). | open, design |
| D6 | noticeable | — | Onboarding Continue drops taps (round 1) | open |
| D5 | polish | T-TABS-02 | never-opened tab shows an indefinite Connecting skeleton card | open |

## Verified this round (phone input only, real link)

| Scenario | Path | Result |
| --- | --- | --- |
| Codex approvals (`-a on-request -s read-only`): edit approval menu rendered above the composer; key bar Down/Up moved the selection on the Mac; empty Send (Return) approved | G-T | pass |
| Codex interrupt with key bar Esc | G-T | pass ("Conversation interrupted" on the Mac 1.6 s after the tap incl. one screen read) |
| Core suite (follow 20 s, two 8 s reads while streaming, two flings, Jump to bottom, keyboard ×2, grid ×2) | W-T | follow 0 flashes / 0 reversals; reads: 4 and 6 moves of 1 px (scaling noise); keyboard 0 reversals; bottom rows match the Mac |
| 60 s follow before/after D7 fix | W-T | 3 → 0 flashes, 5 → 0 down moves, 35 → 0 reversals |
| Cold relaunch after background | G-T | dimmed saved frame + Connecting badge, then live |
| Memory (phys_footprint) | W-T/G-T | 84-99 MB over 30 min of Codex sessions (15:19 → 15:33), no growth trend yet measured as a series (G-10 open) |

## Rig changes

- `tq.py` drives the remote Mac (G-01 for tq scenarios: every command is pasted or
  typed on the phone; the Mac CLI only reads the Mac screen and kills cmux-mobile-host).
- `journey.py`: Settings > Transport is a page now (relay_toggle, settings_transport fixed; item 8).
- `motion.py` upgraded by a tooling agent (G-02, `c436106f`); G-03 in progress.
- G-07: `cause=` on every resize / mirror reset line (`6d6f7f32`).

## Open (next round)

1. D10 (lag after a tab return), D4 (daemon `resized` after reattach), D6.
2. ACCEPTANCE gaps: G-03 row tracker (in progress), G-08 echo probe, G-09 integrity export, G-10 memory series, G-11 netsim, G-12 multi-tab launcher, G-17 red runner (T-REG on 224d15e90f / 2e1369f054), G-14 text selection (product gap).
3. Claude Code session (claude 2.1.292 is on the mini; auth not yet checked through the phone).
4. 60-minute sessions per path (W-D, G-D) per S-AGENT-CODEX; this round ran ~70 min of Codex in total across paths, not 60 continuous on one path.
