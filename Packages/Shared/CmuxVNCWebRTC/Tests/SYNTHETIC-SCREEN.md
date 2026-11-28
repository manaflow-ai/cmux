# Synthetic WebRTC screen checks

Leo: “these feel extremely mockable to be de facto enough”.

The `screen-webrtc-headless` Mac step in `ci/steps.toml` gates WebRTC/VNC/Egress changes with `HeadlessSyntheticScreenStreamTests`:

```
swift test --package-path Packages/Shared/CmuxVNCWebRTC --filter HeadlessSyntheticScreenStreamTests
```

This uses the production host, encoder, ICE connection, viewer and decoder. Only capture
and signaling are replaced. LoopbackSignaling supplies no ICE servers, so media stays on
the runner. The Apple codec requires a managed Mac but no window server, simulator or phone.

A 320×240 NV12 source emits twelve distinct gray markers, spaced by 15 luma units.
The acceptance tolerance is ±6, keeping adjacent bands disjoint so a stale compressed
frame that satisfied the previous marker cannot satisfy the next. Each must decode within two
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

The PR router selects this assertion even on cheap or carried heads. Those heads run only
`screen-webrtc-headless` on the Mac job, with no full Mac tier or simulator boot. The
`cmux/ios-fast` status consumes the selected step's assertion verdict, not the Mac job's
exit status: missing, skipped and timed-out tests cannot pass. Manual verdict recovery
also runs this single suite at the exact PR test-merge commit before posting green.

On owned Macs, the selected integration prepares the checkout's SwiftPM scratch independently
of the fast tier's leased root. A reused checkout can retain `.build` links after their cache
targets are evicted; `owned_spm_scratch.py link` recreates the target and relinks it before
resolution. `Scratch.test_integration_setup_repairs_a_build_link_after_cache_eviction` checks
this case, and `MacIntegrationGateTest` checks that narrow routing includes the setup.

Pinned Mac jobs request both `cmux-mac` and the `xcode-<version>` capability parsed from
`CMUX_CI_XCODE_APP_MACOS_26`; the normal router and verdict recovery share the parser.
A generic Mac label previously selected a runner without the pinned Xcode, failing before
these assertions. `PinnedPipelineRunnerTest` covers version changes, both callers, sparse
checkout dependencies and every pinned job, while preserving external/fork routes.
