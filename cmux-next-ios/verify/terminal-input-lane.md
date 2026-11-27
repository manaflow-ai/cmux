# Terminal input lane and mock removal

Branch `feat-cnx-ios-termlive`, 2026-10-13. This page covers two changes:

- a separate lane for terminal input, so a keystroke or ^C no longer waits
  behind bulk output (PROTOCOL.md "Lanes");
- removal of mock and demo terminal content from signed-in sessions.

## Input lane

### What changed

- **cmux-mobile-link.** `lanes: ["input"]` is negotiated in the first signal and the
  answer. Each transport gets a second stream:
  - WebRTC: data channel `cmux-mobile-input`, ordered and reliable, on its own SCTP
    stream.
  - WireGuard: a second TCP stream to `overlayIP:7420`.

  Each side says hello on the lane, and the lane is used only after the
  peer is heard on it. Each stream's writer sends control frames first, then
  input-lane frames, then bulk data round robin per channel in 16 KiB frames.
  A channel may queue 256 KiB before its sender waits.
- **WireGuard: why a second TCP stream.** Priority inside the smoltcp write
  path would not help. Bytes already in one TCP stream's 256 KiB send buffer
  and 512 KiB stream queue cannot be reordered. The second stream has its own
  buffers and its own loss recovery.
- **Backward compatibility.** Older peers ignore `lanes` and the open frame's
  `"lane":"input"`.
  - With an older Mac, the input channel rides the main stream at input
    priority.
  - An older phone never opens a lane.
- **App.** `DaemonTerminalSession` sends keystrokes (`send`) on their own
  `daemon` channel, opened on the lane (`openInputChannel`). It batches
  keystrokes while a request is out.
  - `resize-surface` stays on the attach channel, because the daemon gives
    geometry authority to the attaching client.
  - A failed lane falls back to the attach channel.
  - A lane request with no answer within 10 s gives the lane up without
    resending, because a doubled Return would run a command twice.
- **Mac.** cmux-mobile-host needs no service change. The link answers the lane, and
  the `daemon` service serves the input channel like any other.

### Live measurement (real cmux-next app on the Mac)

**Mac.** `mini-cmuxs-mac-mini-2`, in its logged-in GUI session.

- It ran the real tagged cmux-next Debug app from the fleet, which bundles
  cmux-mobile-host, the daemon (cmux-tui) and acpmux. No standalone hostd, stub or
  fake ran.
- After: job `f5c14e75cc6d9819b747a626`, tag `cmux-mobile-termlive-lane2`, at
  `0f0188a0db29`.
- Before: job `1b3d29986c9305504647cb3b`, tag `cmux-mobile-termlive-base`, at
  `094f3cd95713`, the branch base before this work.
- The app signed in with the CmuxAuthRuntime DEBUG dev credential, through
  a 0600 credentials file.
- `mobile.allowIPhoneConnections` was turned on through
  `CMUX_NEXT_CONFIG_FILE`.

**Phone side.** `cmux-mobile-lanebench` (cmux-mobile-host test binary) on the laptop. It
uses the same cmux-mobile-link the app does and drives the Mac's daemon exactly as
the app does. It ran with `--exclude-cgnat`.

- It creates two workspaces, A and B, and attaches each on its own `daemon`
  channel.
- In A it starts the flood
  `perl -e '$|=1; for(1..60000){print "y" x 999, "\n"; select(undef,undef,undef,0.0005)}'`.
  That is about 10 Mbit/s of terminal output reaching the phone in every
  run.
- It then types 15 letters into B and measures:
  - **echo**: until B's echo arrives;
  - **ack**: until the `send` reply arrives.
- **^C**: it sends ^C to A followed by a marker command, and measures until
  the Mac's screen of A shows the marker (`read-screen`).
- "Before" is the base app with `--no-input-lane`, which is the old app
  behavior: input on the attach channel, single stream.

**Results.** Each cell is median / p90 / max in ms, over 15 samples.

| Transport, path | Echo in B, before | Echo in B, after | `send` ack, before | `send` ack, after | ^C to quiet, before → after |
| --- | --- | --- | --- | --- | --- |
| WebRTC direct | 365 / 946 / 1071 | **2.0 / 2.6 / 34** | 365 / 946 | **0.5 / 0.9** | 2801 → **57** |
| WebRTC TURN (`--relay-only`) | 1729 / 2629 / 2850 | **16 / 84 / 1089** | 1729 / 2629 | **15 / 84** | 5380 → **1815** |
| WireGuard direct | 2.3 / 1877 / 1900 | **2.1 / 2.4 / 2.8** | 0.7 / 1876 | **0.6 / 0.8** | 31 → 63 |
| WireGuard TURN (`--relay-only`) | 2701 / 7414 / 10032 | **150 / 1093 / 1385** | 2701 / 7414 | **14 / 15** | 87 → 62 |

Idle echo, with no flood, was 2 to 25 ms in both builds. The `send` ack now
stays at the path RTT in every case, because the reply rides the lane.

B's echo is terminal output on the main stream, next to A's flood. Round
robin bounds its wait, and it fell from seconds to milliseconds.

On WireGuard over TURN, B's echo still reaches 1.1 to 1.4 s at p90. This is
the main stream's own TCP and TURN queueing; only input has its own stream.

Raw JSON was in `/tmp/termlive-results` and is not committed.

A first "after" run is excluded. It started while the Mac's cmux-tui was
still parsing an earlier flood, so its ^C times were 11 to 22 s, set by the
Mac and not the link. The rerun waited for the daemon to be idle before each
case.

After the merge of `origin/feat-cnx-ios` with fastconn (`73bcfad84f1a`,
fleet job `8405a224218ceb19d87ac9b0`), one recheck ran with the same flood.
Values are median / p90 in ms.

| Transport | Echo in B | `send` ack | ^C |
| --- | --- | --- | --- |
| WebRTC direct | 2.0 / 2.9 | 0.5 / 0.8 | 28.5 |
| WireGuard direct | 2.3 / 2.5 | 0.6 / 0.8 | 28.7 |

### Findings outside this change

- **cmux-tui loses the PTY under an unthrottled flood.** This is reproduced
  over the Mac's local socket, without mobile. About 1 to 3 s into
  `yes | head -c 30000000` or `seq 1 3000000`, every `send` to that surface
  returns `Broken pipe (os error 32)`, and the terminal leaves
  `list-terminals`. ^C can then never reach it. The flood above is
  rate-limited for this reason. This is for the cmux-tui owner.
- **Intermittent slow WebRTC transfers.** Running `cmux-mobile-dial` 4 MB echo
  against the same app, most runs reached 125 to 245 Mbit/s, but 7 of about
  34 runs fell to 3 to 6 Mbit/s.
  - This happened both with and without the lane (1 of 8 and 3 of 8 in the
    interleaved A/B, `webrtc-ab.txt`).
  - With the `cmux-mobile-input` channel opened but unused, 5 of 5 runs were fast.
  - Not reproduced on loopback (`throughput_probe`, ignored test).
  - It needs a separate look; it is not clearly caused by the lane.
- **Simulator check not completed.** The real iOS app (Debug,
  `cmux-mobile-tl-ios26`) signed in with the dev credential. Its pairing step
  offered only "Aziz's MacBook Pro is online", not the mini.
  - Continuing would have dialed the user's own Mac, so the run stopped
    there. The simulator was then deleted.
  - The app-side lane is covered by
    `DaemonTerminalSessionTests.keystrokesRideTheInputLane`, and the
    link side by the measurement above.

### Tests

- `cargo test` and `clippy -D warnings` pass, including:
  - `link::tests` for priority and round robin under an 8 MiB flood, lane
    bypass, a lane the peer never attached, chunking, and the open frame's
    wire format;
  - `loopback.rs` for the lane over WebRTC and WireGuard, and fallback with
    an older Mac.
- `swift test` passes all 211 tests in CmuxMobileKit after the fastconn merge,
  BrowserStreamTests included. `nx-remote` could not reach
  `cmux-lawrence-2` (REPAIR.md row 114), so the tests ran on the mini.
- The iOS simulator Debug and Production builds compile.

## Mock-removal audit

**Root cause.** `GhosttyTerminalTabContent` built `live ?? MockTerminalSession()`
in every build configuration. A terminal tab whose Mac session did not exist
yet therefore ran the scripted mock shell (ls, git log, a cargo build, htop).
That is what the user saw on a Production phone.

| Surface | Path that could show mock content | Fix |
| --- | --- | --- |
| Terminal tab | Fell back to `MockTerminalSession` until the live session existed. | `TerminalSessionChoice`: the live session, or `PendingTerminalSession` with `TerminalConnectingView` (skeleton, spinner, "Connecting to <Mac>…" / "Reattaching…"). It is driven by `DaemonTerminalSession.connectionState`. The mock is DEBUG-only and needs Mock data. |
| Terminal Files and Links | `MockArtifactSource` fallback. | `UnavailableArtifactSource` ("Connect to your Mac to preview this."). |
| Agent chat | `MockAgentSession` for any session without a live source. | `DisconnectedAgentSource`. The mock needs DEBUG plus Mock data. |
| Chief | `ChiefMockBackend` while no link was up, including after a link dropped. | `ChiefOfflineBackend` (empty, disconnected). |
| Feed | `FeedStore.shared` seeded with mock items. | Empty unless DEBUG plus Mock data. |
| Workspaces, new workspace | Sample Macs and `MockWorkspaceCreationBackend` before live data. | No sample Macs outside DEBUG. `UnavailableWorkspaceCreationBackend` ("Not connected to this Mac"). |
| Developer settings | `cmuxMobile.dev.mockData`, `launchDemo` and relay-only persisted in UserDefaults and were read in every build. | Non-DEBUG builds never read them, and Production removes them at launch (`DeveloperOptions.removeStoredValues`). |
| Demo drivers, mock files | Compiled into every build. | All `Mock*`, demo scripts and `MockMacLink` are `#if DEBUG`. |
| Build check | `demo-build.sh` grepped 7 strings in the executable only. | `scripts/check-production-binary.sh` scans every Mach-O in the bundle for 23 DEBUG-only strings, including the mock terminal's script lines. All 23 are found in a Debug build (`CmuxMobileApp.debug.dylib`) and none in Production. |

Tests: `TerminalMockRemovalTests`, `AgentMockRemovalTests`,
`ChiefMockRemovalTests`, `DeveloperOptionsTests` and
`DaemonTerminalSessionTests.reportsConnectingThenAttached`.

## Cleanup

- The apps, the credentials file, the tagged app state on the mini and the
  local token files are deleted. Debris from the first runs was closed.
- The tagged apps' Keychain entries for the dev account may remain on the
  mini, under bundle ids `com.cmuxterm.app.debug.cmuxMobile.termlive.*`.
