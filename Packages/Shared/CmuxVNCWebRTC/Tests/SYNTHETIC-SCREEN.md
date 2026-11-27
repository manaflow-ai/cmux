# Synthetic WebRTC screen check

Leo: “these feel extremely mockable to be de facto enough”.

`swift test --package-path Packages/Shared/CmuxVNCWebRTC --filter SyntheticScreenStreamTests`

FlowSuite routes changes to WebRTC, ScreenKit, and the phone screen-sharing page to this
macOS package test in the PR pipeline. It uses the production host, encoder, ICE connection,
viewer, decoder and Mac ScreenVideoView. Only the capture source and signaling service are
replaced. LoopbackSignaling supplies no ICE servers, so the media stays on the runner.

A 320×240 NV12 source changes between distinct gray pictures twelve times. Each change must
reach `AVSampleBufferVideoRenderer.displayedPixelBuffer()` within two seconds; the source
change to displayed-pixel p95 must stay below 250 ms. Decoded and received counts must also
advance. Decoder callbacks alone cannot satisfy the display assertion. Initial connection
has a separate ten-second bound. The test prints `SCREEN_WEBRTC_SYNTHETIC` with counts,
p95, process CPU seconds and wall time; report those measured costs with the CI receipt.
The full test has a one-minute outer bound, with no soak or fixed warmup.

This is a **Mac viewer** check on a managed Mac, without simulator boot or a phone. It does
not prove iOS Metal rendering, physical display scan-out, ScreenCaptureKit permissions,
real screen capture, radio/relay behavior, real-device thermals or hardware speed. The
phone `cmux.rd` renderer has its separate simulator test. iOS WebRTC rendering still needs
its own simulator coverage; don't count this check as that coverage. ScreenRules uses its
existing no-channel behavior, so this check does not prove Rust screen policy decisions.
