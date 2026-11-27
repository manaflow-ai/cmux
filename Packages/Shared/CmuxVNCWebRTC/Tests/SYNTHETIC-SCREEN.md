# Synthetic WebRTC screen checks

Leo: “these feel extremely mockable to be de facto enough”.

The `screen-webrtc-headless` Mac step in `ci/steps.toml` gates WebRTC/VNC/Egress changes with `HeadlessSyntheticScreenStreamTests`:

```
swift test --package-path Packages/Shared/CmuxVNCWebRTC --filter HeadlessSyntheticScreenStreamTests
```

This uses the production host, encoder, ICE connection, viewer and decoder. Only capture
and signaling are replaced. LoopbackSignaling supplies no ICE servers, so media stays on
the runner. The Apple codec requires a managed Mac but no window server, simulator or phone.

A 320×240 NV12 source emits twelve distinct gray markers. Each must decode within two
seconds; source-change-to-decode p95 must stay below 250 ms. Received/decoded counts and
pixel dimensions must match too. Initial connection has a separate ten-second deadline.
`SCREEN_WEBRTC_HEADLESS` reports marker/decoded/received counts, p95, process CPU seconds
and wall time. Report measured costs with the native receipt; neither compilation time
nor the one-minute outer test deadline is a measured runtime.

The separate opt-in `SyntheticScreenStreamTests` attaches the production Mac ScreenVideoView
to a window and verifies those markers with `displayedPixelBuffer()`. Run it through
`cmux-ci run --display`, with `CMUX_WEBRTC_DISPLAY_TEST=1`, on the managed fleet. Its
`SCREEN_WEBRTC_SYNTHETIC` receipt measures source-change-to-displayed-pixels with the same
limits. This display check is not part of the headless gate.

Neither test proves iOS Metal rendering, physical scan-out, ScreenCaptureKit permissions,
real screen capture, radio/relay behavior, real-device thermals or hardware speed. The
phone `cmux.rd` renderer has a separate simulator test. iOS WebRTC rendering still needs
its own simulator coverage; don't count the Mac viewer as that coverage. ScreenRules uses
its existing no-channel behavior, so these checks don't prove Rust screen policy decisions.
FlowSuite names the headless flow; `ci/steps.toml` owns its execution on PRs. This real
asynchronous integration test runs outside the virtual-clock fast tier.
