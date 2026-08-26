public import Foundation

/// Pure evidence-based liveness policy for one streamed panel.
///
/// A browser stream is legitimately silent while the page is idle, so frame
/// silence alone proves nothing. The reliable desync signal is unanswered
/// interaction: the user sent input, input repaints pages, and no frame (and
/// no fresh subscription) followed. When that happens the stream should be
/// re-armed; a Mac-side `stream.start` replaces the session idempotently, so
/// a false positive costs one redundant frame.
public struct BrowserStreamRecoveryPolicy: Sendable, Equatable {
    /// How long an input may go unanswered before the stream is suspect.
    public let inputSilenceThreshold: TimeInterval
    /// Minimum spacing between restart requests.
    public let restartBackoff: TimeInterval

    private var lastInputAt: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private var lastRestartAt: TimeInterval?

    /// Creates a policy with the given thresholds.
    public init(inputSilenceThreshold: TimeInterval = 2.5, restartBackoff: TimeInterval = 4) {
        self.inputSilenceThreshold = inputSilenceThreshold
        self.restartBackoff = restartBackoff
    }

    /// Records user input forwarded to the Mac.
    public mutating func noteInput(at timestamp: TimeInterval) {
        lastInputAt = timestamp
    }

    /// Records a displayed frame; frames are the only proof of liveness.
    public mutating func noteFrame(at timestamp: TimeInterval) {
        lastFrameAt = timestamp
    }

    /// Records an issued restart, for backoff.
    public mutating func noteRestart(at timestamp: TimeInterval) {
        lastRestartAt = timestamp
    }

    /// Clears interaction evidence, e.g. when a new subscription starts.
    public mutating func reset() {
        lastInputAt = nil
        lastFrameAt = nil
        lastRestartAt = nil
    }

    /// Whether unanswered input now justifies re-arming the stream.
    /// - Parameter timestamp: The current monotonic time.
    public func shouldRestart(at timestamp: TimeInterval) -> Bool {
        guard let lastInputAt else { return false }
        guard timestamp - lastInputAt >= inputSilenceThreshold else { return false }
        if let lastFrameAt, lastFrameAt >= lastInputAt { return false }
        if let lastRestartAt, timestamp - lastRestartAt < restartBackoff { return false }
        return true
    }
}
