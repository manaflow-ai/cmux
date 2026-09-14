import Foundation

/// Records the independent lifecycle signals that make a Cloud terminal usable.
///
/// Attachment, replay, and renderer callbacks are delivered by different
/// owners and may arrive in any order. The gate retains each observation and
/// opens once a frame newer than the current generation baseline was presented
/// in an effectively visible pane.
struct CloudTerminalStartupReadiness: Equatable, Sendable {
    private(set) var baselineFrame: UInt64 = 0
    private(set) var attached = false
    private(set) var replayApplied = false
    private(set) var presentedFrame: UInt64?

    /// Whether all startup signals have converged for this generation.
    var isReady: Bool { attached && replayApplied && presentedFrame != nil }

    /// Starts a new presentation generation and rejects frames from the prior one.
    mutating func begin(baselineFrame: UInt64) {
        self.baselineFrame = baselineFrame
        attached = false
        replayApplied = false
        presentedFrame = nil
    }

    /// Starts a visible presentation episode without discarding attach/replay state.
    /// Frames rendered while hidden are older than this baseline and cannot open
    /// readiness when the pane is revealed.
    mutating func beginVisiblePresentation(baselineFrame: UInt64) {
        self.baselineFrame = baselineFrame
        presentedFrame = nil
    }

    /// Records the attach acknowledgement and returns whether this opened readiness.
    @discardableResult
    mutating func markAttached() -> Bool {
        let wasReady = isReady
        attached = true
        return !wasReady && evaluateIfReady()
    }

    /// Records that the remote replay reached the local terminal parser.
    @discardableResult
    mutating func markReplayApplied() -> Bool {
        let wasReady = isReady
        replayApplied = true
        return !wasReady && evaluateIfReady()
    }

    /// Records a renderer frame and returns whether this opened readiness.
    @discardableResult
    mutating func markFramePresented(
        sequence: UInt64,
        rendererPresented: Bool,
        effectivelyVisible: Bool
    ) -> Bool {
        guard replayApplied,
              sequence > baselineFrame,
              rendererPresented,
              effectivelyVisible else { return false }
        guard presentedFrame == nil else { return false }
        presentedFrame = sequence
        return evaluateIfReady()
    }

    private mutating func evaluateIfReady() -> Bool {
        guard attached, replayApplied, let presentedFrame else { return false }
        return presentedFrame > baselineFrame
    }
}
