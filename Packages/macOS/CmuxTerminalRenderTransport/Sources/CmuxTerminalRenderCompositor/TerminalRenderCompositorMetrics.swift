internal import Foundation

/// One constant-size counter mutation at the Swift host's final compositor
/// boundary. A process-scoped recorder can consume these events without
/// retaining a compositor view or crossing onto the AppKit main actor.
public enum TerminalRenderCompositorMetricEvent: Sendable {
    case receivedFrame
    case admittedFrame
    case submittedBlit
    case coalescedFrame
    case rejectedFrame
    case drawableUnavailable
    case metalUnavailable
}

/// Synchronous constant-time hook for process-scoped compositor accounting.
public typealias TerminalRenderCompositorMetricEventHandler = @Sendable (
    TerminalRenderCompositorMetricEvent
) -> Void

/// Thread-safe aggregate used by runtime diagnostics and acceptance tooling.
/// The compositor still retains its own per-view counters.
public final class TerminalRenderCompositorMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = TerminalRenderCompositorMetrics()

    public init() {}

    public func record(_ event: TerminalRenderCompositorMetricEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .receivedFrame:
            storage.receivedFrames &+= 1
        case .admittedFrame:
            storage.admittedFrames &+= 1
        case .submittedBlit:
            storage.submittedBlits &+= 1
        case .coalescedFrame:
            storage.coalescedFrames &+= 1
        case .rejectedFrame:
            storage.rejectedFrames &+= 1
        case .drawableUnavailable:
            storage.drawableUnavailableEvents &+= 1
        case .metalUnavailable:
            storage.metalUnavailableFrames &+= 1
        }
    }

    public func snapshot() -> TerminalRenderCompositorMetrics {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Returns the exact prior interval and begins a fresh interval while
    /// holding one lock, so reset cannot discard an in-flight metric event.
    @discardableResult
    public func snapshotAndReset() -> TerminalRenderCompositorMetrics {
        lock.lock()
        defer { lock.unlock() }
        let result = storage
        storage = TerminalRenderCompositorMetrics()
        return result
    }
}

/// Bounded compositor counters suitable for performance assertions.
public struct TerminalRenderCompositorMetrics: Equatable, Sendable {
    /// Authenticated frames offered to the final compositor boundary.
    public internal(set) var receivedFrames: UInt64 = 0

    /// Frames admitted by the final presentation fence.
    public internal(set) var admittedFrames: UInt64 = 0

    /// Full IOSurface-to-drawable blits committed by the Swift host.
    public internal(set) var submittedBlits: UInt64 = 0

    /// Admitted frames discarded in favor of a newer pending frame.
    public internal(set) var coalescedFrames: UInt64 = 0

    /// Frames rejected before Metal import or command submission.
    public internal(set) var rejectedFrames: UInt64 = 0

    /// Drawable acquisition misses. One pending frame may contribute more
    /// than one event when AppKit asks the compositor to retry.
    public internal(set) var drawableUnavailableEvents: UInt64 = 0

    /// Admitted frames released because Metal could not encode a blit.
    public internal(set) var metalUnavailableFrames: UInt64 = 0

    /// Creates zeroed counters.
    public init() {}
}
