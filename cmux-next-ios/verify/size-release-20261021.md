# Size release over the real link (2026-10-21/22)

Question: when the phone stops showing a Mac terminal, does the Mac pane get its own
size back, within the bounds in PROTOCOL.md "Terminal size claims"?

## Rig

| Part | What |
| --- | --- |
| Mac | Fleet build `8e052c79141dda4c95a4e792` (aws-m4pro-7), tag `msr-a66181df`, `--production` Debug app at `a66181df` (this PR after review fixes). Its bundled `cmux-tui` and `cmux-mobile-host` are the same tree (`cmux-mobile-host.version` commit `a66181df…`). Hidden on mini-cmux11s (`open -g -j -n`, isolated config, credentials file and pairing seed via `open --env`); never activated |
| Phone | TestFlight-config simulator app of `a66181df` (`testflight-build.sh --unsigned --no-asc --allow-package-drift --config TestFlight`, Xcode 26.6) on one headless iPhone 17 Pro (iOS 26.5) on mini-cmux8s |
| Link | Simulator (mini-cmux8s) to the Mac (mini-cmux11s) over production signaling and WireGuard. No local socket or loopback |
| Mac pane | A hidden rig app draws no window, so `verify/scripts/size_probe.py --mac-view 120x39` holds a Mac view (`device_kind: mac`) of the terminal at 120x39 on the rig's daemon and samples the PTY grid (`vt-state`) and participants (`get-size-state`) every 0.2 s. Policy Fit everyone (`smallest`), so the phone narrows the grid to 53x39 while it claims |
| Driver | `verify/e2e/size_release.py` (AXe taps). Times are from the end of the driver's action (its taps take about 1 s each) to the first sample at 120x39 |

## Results

| Path | Mechanism | Before / during | Mac pane back at 120x39 | Bound |
| --- | --- | --- | --- | --- |
| Back to the workspace list | page disappears, release after 1 s | 120x39 / 53x39 | 0.44 s after the back tap finished (2.65 s from its start) | 1 s + RTT |
| Tab grid opened | page not interactive, release after 1 s | 120x39 / 53x39 | 1.19 s (2.19 s from the tap) | 1 s + RTT |
| Files and Links over the page | covered, release after 1 s | 120x39 / 53x39 | already back when the sheet's taps ended (2.15 s from the first tap) | 1 s + RTT |
| App to the background (home) | release at once | 120x39 / 53x39 | 1.4 s (1.61 s from the home press; AXe's own latency included) | one round trip |
| Force quit (`simctl terminate`) | no release; lease ends | 120x39 / 53x39 | 44.3 s | 45 s |
| hostd SIGTERM (iPhone connections off, the app quitting) | hostd releases before exit | 53x39 | 0.02 s; the phone reclaimed 2.5 s later when the app restarted hostd | 0.7 s |
| hostd SIGKILL (crash) | unexpected drop: departed-view hold | 53x39 | not restored, by design: the phone reattached 2.3 s later and the grid never moved (no resize, no reflow) | hold 30 s, capped by the lease |
| Grid open and closed 5 times (taps ~1.2 s apart) | debounce 1 s | 53x39 | each visit (>1 s) released and reclaimed: 120x39 for about 0.4 s each time | the 1 s debounce |
| Coming back (every path above) | resize-surface on show | 120x39 | phone grid 53x39 again within 0.4-0.6 s of the page showing | n/a |

Not run live (unit tests cover them): sign-out, removing the phone on the Mac (`removed`),
a network loss without the app dying (same daemon path as the force quit: keepalive closes,
lease caps), a sub-second switch (AXe taps are too slow; `TerminalSizeClaimerTests.aQuickSwitchBackSendsNothing`),
multiple phones.

Evidence (git-ignored, on mini-cmux8s): `~/msr-20261021/evidence/run2/` (results.json,
run.log, shots/), `run3/`, and the probe samples `~/msr-20261021/probe.jsonl`. Run 1 failed
on driver navigation (the grid's Done and the workspace's back control); fixed in the driver.
