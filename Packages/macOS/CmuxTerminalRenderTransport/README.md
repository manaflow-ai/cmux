# CmuxTerminalRenderTransport

This package owns only the renderer-to-Swift frame plane. It has no PTY,
terminal-scene, input, topology, or worker-control messages.

`CmuxTerminalRenderProtocol` is a Foundation-only target containing immutable
IDs, metadata, a fixed-width codec, and latest-frame acceptance. The macOS
`CmuxTerminalRenderTransport` target adds the IOSurface and Mach bridge.
`CmuxTerminalRenderCompositor` is the deliberately small host path: it imports
an authenticated IOSurface and commits one full-surface Metal blit. It owns no
Ghostty terminal, parser, font grid, glyph atlas, shader pipeline, or PTY.

The host creates a receiver before launching a renderer, gives the endpoint to
the child, then binds the receiver to the launched PID and effective UID:

```swift
let receiver = try TerminalRenderFrameReceiver(initialFence: fence)

// Launch the renderer with receiver.endpoint through the authenticated control plane.
try await receiver.authorize(worker: launchedWorkerIdentity)

switch try await receiver.receive(timeoutMilliseconds: 50) {
case .frame(let frame):
    switch frame.metadata.completionFence {
    case .producerCompleted:
        present(frame.surface)
    case let .sharedEvent(eventID, value):
        present(frame.surface, after: (eventID, value))
    }
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
Sequence counters never wrap within an epoch or generation; the owner creates
a new epoch or generation before exhaustion.

Ghostty's Metal completion callback sends `.producerCompleted` frames only
after the producer command buffer finishes. A renderer that sends earlier may
instead use `.sharedEvent`; its event handle remains outside this package, and
the control plane must import and wait for it without blocking the main thread.
Both modes require an explicit surface-release acknowledgement before the
renderer reuses a pool slot.

## Host composition

Create one `TerminalRenderCompositorView` for one exact presentation fence.
Its required release handler forwards `TerminalRenderFrameRelease` through the
authenticated control plane after the host blit completes, or immediately
when a pending frame is superseded without a blit. This prevents the worker
from rewriting an IOSurface while the host GPU is still reading it.

The view repeats the complete fence check to prevent accidental cross-terminal
routing. It permits one in-flight blit and retains only the newest pending
frame. Replacing the fence installs a new Metal layer, so a committed frame
from the detached generation cannot become visible in the replacement view.

Metal captures label host work `cmux host compositor: one IOSurface blit`.
Ghostty draw commands must appear under the renderer-worker PID. The cmux app
PID may show this copy command for an externally rendered terminal.
