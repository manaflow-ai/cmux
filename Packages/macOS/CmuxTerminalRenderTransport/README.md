# CmuxTerminalRenderTransport

This package owns only the renderer-to-Swift frame plane. It has no PTY,
terminal-scene, input, topology, or worker-control messages.

`CmuxTerminalRenderProtocol` is a Foundation-only target containing immutable
IDs, metadata, a fixed-width codec, and latest-frame acceptance. The macOS
`CmuxTerminalRenderTransport` target adds the IOSurface and Mach bridge.

The host creates a receiver before launching a renderer, gives the endpoint to
the child, then binds the receiver to the launched PID and effective UID:

```swift
let receiver = try TerminalRenderFrameReceiver(initialFence: fence)

// Launch the renderer with receiver.endpoint through the authenticated control plane.
try await receiver.authorize(worker: launchedWorkerIdentity)

switch try await receiver.receive(timeoutMilliseconds: 50) {
case .frame(let frame):
    present(frame.surface, after: frame.metadata.completionFence)
case .dropped:
    break
case .timedOut:
    break
}
```

The renderer sends an IOSurface without waiting for queue capacity:

```swift
let sender = try TerminalRenderFrameSender(endpoint: endpoint)
let result = try await sender.send(surface: renderedSurface, metadata: metadata)
if result == .droppedQueueFull {
    // Keep rendering current state. An obsolete intermediate frame was discarded.
}
```

The kernel queue is bounded. Every message carries a 256-bit capability and a
kernel audit trailer. Swift rejects the wrong PID, UID, capability, daemon
lifetime, renderer epoch, terminal identity or epoch, presentation identity or
generation, dimensions, pixel format, color space, completion fence, and stale
sequence before it accepts a frame. Metadata rejections occur before IOSurface
import. Imported surface dimensions and pixel format are checked again.

The shared Metal event handle is intentionally outside this package. The
control plane must import the event identified by `completionFence.eventID`,
wait for its value without blocking the main thread, and send explicit surface
release acknowledgements before a renderer reuses a pool slot.
