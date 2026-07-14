# CmuxSimulator

The iOS Simulator surface domain for cmux: device catalog parsing, the
boot/attach/shutdown lifecycle, the display-capture backend seam, the pane
model behind the simulator surface, and the `cmux simulator` argument parser.

## Layering

A leaf package (no dependencies). The app target hosts the SwiftUI pane view
and the socket/CLI wiring; everything testable lives here.

- `Catalog/` — `SimulatorDeviceCatalog` parses `simctl list devices --json`.
  `SimulatorDeviceUDID` only constructs from a well-formed UUID, so the
  `"booted"` alias (which targets an arbitrary, possibly foreign simulator)
  is unrepresentable by design.
- `Simctl/` — `SimctlCommandRunning` is the process seam; the production
  `SimctlCommandRunner` actor spawns `xcrun simctl`.
- `Lifecycle/` — `SimulatorLifecyclePolicy` holds the pure decisions
  (boot vs. attach vs. refuse; shutdown only what cmux booted);
  `SimulatorDeviceSession` applies them with real effects.
- `Capture/` — `SimulatorDisplayCapturing` is the backend seam.
  `SimctlScreenshotCaptureBackend` is the shipped v1 backend: periodic
  `simctl io screenshot` captures, deduplicated by
  `SimulatorFrameDeduplicator`. Richer backends (CoreSimulator framebuffer
  service, ScreenCaptureKit) conform to the same protocol.
- `PaneModel/` — `SimulatorPaneModel`, the `@MainActor @Observable` model the
  pane view renders.
- `CLIParsing/` — `SimulatorCLIParser`, the lexical parser for the
  `cmux simulator` namespace.

## Testing

Everything takes its dependencies through `init`; tests inject a fake
`SimctlCommandRunning` that replays canned outputs and records invocations:

```swift
let runner = RecordingSimctlRunner(responses: [
    .init(matching: ["list", "devices", "--json"], data: fixture),
    .init(matching: ["boot", udid.rawValue], data: Data()),
])
let session = SimulatorDeviceSession(udid: udid, runner: runner)
let ownership = try await session.open()
#expect(ownership == .bootedByCmux)
#expect(await runner.recordedInvocations.contains(["boot", udid.rawValue]))
```

Run with:

```bash
swift test --package-path Packages/macOS/CmuxSimulator
```
