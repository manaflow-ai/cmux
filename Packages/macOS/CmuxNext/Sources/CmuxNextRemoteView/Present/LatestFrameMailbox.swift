import Foundation
import Synchronization

/// A one-slot hand-off from the decoder to a presenter: latest frame wins.
/// `post` replaces an undisplayed frame (counted as discarded) and says
/// whether the caller must schedule a drain; while a drain is pending, more
/// posts only replace the slot, so at most one drain is ever scheduled and
/// nothing queues. No frames, no drains: zero wakeups at rest.
public nonisolated final class LatestFrameMailbox<Frame: Sendable>: Sendable {
    private struct State {
        var frame: Frame?
        var drainScheduled = false
        var discarded = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Stores `frame`. True when the caller must schedule one drain.
    public func post(_ frame: Frame) -> Bool {
        state.withLock { state in
            if state.frame != nil { state.discarded += 1 }
            state.frame = frame
            if state.drainScheduled { return false }
            state.drainScheduled = true
            return true
        }
    }

    /// Takes the newest frame and ends the scheduled drain.
    public func take() -> Frame? {
        state.withLock { state in
            state.drainScheduled = false
            defer { state.frame = nil }
            return state.frame
        }
    }

    /// Frames replaced before they were shown.
    public var discardedCount: Int { state.withLock { $0.discarded } }
}
