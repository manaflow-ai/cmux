import Foundation
import CmuxNextCompat

/// A one-slot hand-off from the decoder to a presenter: latest frame wins.
/// `post` replaces an undisplayed frame (counted as discarded) and says
/// whether the caller must schedule a drain; while a drain is pending, more
/// posts only replace the slot, so at most one drain is ever scheduled and
/// nothing queues. No frames, no drains: zero wakeups at rest.
///
/// It also keeps the frame on screen (`recordShown`), written by the render
/// queue in its own turn, so the main thread reads it with no hop per frame.
public nonisolated final class LatestFrameMailbox<Frame: Sendable>: Sendable {
    private struct State {
        var frame: Frame?
        var drainScheduled = false
        var discarded = 0
        var shown: Frame?
        var shownNoticeArmed = true
    }

    /// What `recordShown` replaced, and whether main asked to hear of this frame.
    public nonisolated struct Shown: Sendable {
        /// The frame drawn now.
        public let frame: Frame
        /// The frame that was on screen before it (nil for the first).
        public let replaced: Frame?
        /// True when this is the first frame shown since `armShownNotice()` (or since the mailbox was
        /// made): the caller tells main once. Later frames answer false until the next arm.
        public let noticeAsked: Bool
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

    /// Records `frame` as the one on screen. Call it from the one queue that draws, in the draw's turn,
    /// so records keep draw order.
    public func recordShown(_ frame: Frame) -> Shown {
        state.withLock { state in
            let shown = Shown(frame: frame, replaced: state.shown, noticeAsked: state.shownNoticeArmed)
            state.shown = frame
            state.shownNoticeArmed = false
            return shown
        }
    }

    /// Asks that the next recorded frame answer `noticeAsked` (a pane that starts again waits for its
    /// first frame).
    public func armShownNotice() {
        state.withLock { $0.shownNoticeArmed = true }
    }

    /// The frame on screen now, nil before the first.
    public var lastShown: Frame? { state.withLock { $0.shown } }
}
