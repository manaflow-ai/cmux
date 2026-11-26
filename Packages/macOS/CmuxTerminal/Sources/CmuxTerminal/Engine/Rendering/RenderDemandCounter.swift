public import CmuxTerminalCore
internal import Foundation

/// A retain-counted render-demand gate.
///
/// Replaces the legacy `GhosttyRenderedFrameNotificationDemand` /
/// `GhosttyTickNotificationDemand` namespace enums (static lock-guarded
/// counters): the engine owner constructs one counter per notification kind
/// and injects it into the producers that gate work on it.
///
/// Isolation design: the blueprint sketched an actor here, but the hot reader
/// is `GhosttyMetalLayer.nextDrawable()` on the renderer thread, a
/// synchronous override that cannot await; retain/release arrive from the
/// main actor. A lock around one `Int` is the sanctioned shape for a tiny
/// value read by synchronous off-isolation code, so the counter stays
/// nonisolated and `Sendable` with identical observable behavior to the
/// legacy statics.
public final class RenderDemandCounter: RenderDemandGating, Sendable {
    private final class Retention: RenderDemandRetention, Sendable {
        private let counter: RenderDemandCounter
        private let released = NSLock()
        // SAFETY: guarded by `released`; makes release() idempotent when
        // called from multiple cleanup paths.
        nonisolated(unsafe) private var didRelease = false

        init(counter: RenderDemandCounter) {
            self.counter = counter
        }

        func release() {
            released.lock()
            let shouldRelease = !didRelease
            didRelease = true
            released.unlock()
            guard shouldRelease else { return }
            counter.releaseOne()
        }
    }

    private let lock = NSLock()
    // SAFETY: guarded by `lock`; written from retain/release callers and read
    // synchronously from the renderer thread via `isActive`.
    nonisolated(unsafe) private var count = 0

    /// Creates an inactive counter.
    public init() {}

    /// Registers one unit of demand until the returned retention is released.
    public func retain() -> any RenderDemandRetention {
        lock.lock()
        count += 1
        lock.unlock()
        return Retention(counter: self)
    }

    /// Whether at least one retention is outstanding.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }

    private func releaseOne() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }
}
