# Synthetic screen-sharing viewer check

Leo, 2026-11-27: "these feel extremely mockable to be de facto enough".

Detector: `CmuxMobileBrowserStreamTests/SyntheticScreenSharingTests`, selected by
FlowSuite's `screen-share-synthetic-frames` for viewer, transport, rd host/link/protocol
and test changes, plus the kit manifest/resolution and both Rust workspaces’
manifest, lockfile and toolchain changes. `cmux/ios-fast` runs it for those paths too, including broad
changes that otherwise fall back to compile-only. The normal kit simulator suite
runs it too.

The host fixture encodes 20 changing grey pictures with VideoToolbox, at both
320×240 and 1280×720. Its Annex-B frames enter the production `Sink` used by the
cmux.rd screen viewer, then `BrowserVideoDecoder`, VideoToolbox and
`AVSampleBufferVideoRenderer`. The test reads `displayedPixelBuffer()` and checks
each frame's dimensions and grey value. A decoded callback or successful enqueue
alone cannot pass: a frozen, black or stale display fails.

Every frame must arrive, decode and present. Each picture has a 2-second failure
bound; delivery-to-displayed-pixels p95 must stay below 250 ms. The p95 uses the
nearest-rank sample (including the first frame); its clock starts when the encoded
frame enters the sink, so it does **not** claim capture/encode/network latency.
The bound catches a visibly stalled viewer and leaves room for simulator scheduling.
`SCREEN_SHARE_SYNTHETIC` reports dimensions, counts, p95 milliseconds, total wall
seconds (encoding included) and process CPU seconds. Process CPU includes any other
test work in the runner; use the isolated suite to measure its cost.

```sh
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg test --arg only=CmuxMobileBrowserStreamTests/SyntheticScreenSharingTests \
  --artifact artifacts/ios-sim/evidence.zip
```

This uses an existing simulator test target and requires no physical phone. Compile
and simulator setup are separate costs from the measured warm test body; use the
existing kit/FlowSuite run instead of booting a simulator for an hourly probe.

Scope: this detector covers the cmux.rd viewer. The separate WebRTC
`ScreenSessionView`/`ScreenVideoView` path needs its own synthetic check; this
receipt must not be counted as coverage of that path.

Limits: the synthetic source bypasses desktop capture permission and the network.
Pairing, version skew, Braid carriers and roaming have their own protocol tests.
This decoder/display check does not establish real radio behavior, display scanout,
hardware decoder throughput, thermal behavior, or full-screen viewer layout. Keep
occasional real-device/capture sanity checks advisory; none is a prerequisite for
this gate.
