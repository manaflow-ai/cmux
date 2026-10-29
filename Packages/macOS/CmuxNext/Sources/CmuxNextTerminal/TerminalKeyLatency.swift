public import CmuxNextInput
public import CmuxNextInputCore
public import CmuxNextWakeups

/// The app's input latency tracker as the terminals see it: the echo stages' sink
/// and the daemon attachments' key stamp sink. The composition root installs it before the first terminal
/// (``TerminalEchoStages/install(_:)``) and hands it to each local daemon terminal.
///
/// - ``dispatchingKey`` is the key slot `sendEvent` is dispatching: a surface arms its echo on it, and Ghostty's
///   write of the key sends it to the daemon as the key's flow.
/// - ``terminalEcho(_:_:at:)`` stamps `echoParsed` and `contentSubmitted` (which also marks the slot's frame
///   update). A key that ends with no frame (no echo, a hidden surface, superseded, closed) stamps nothing: its slot
///   closes at the tracker's content deadline, which comes after the stage's window, since the deadline counts from
///   the key's commit and the window from its dispatch.
/// - ``keyEchoStamped(flow:_:decodedAt:)`` stamps the daemon's stages.
///
/// Every call but ``dispatchingKey`` comes from any thread and only stamps the tracker's lock-free slot table.
public nonisolated final class TerminalKeyLatency: TerminalEchoLatencySink, TerminalKeyStampSink {
    private let tracker: InputLatencyTracker

    public init(tracker: InputLatencyTracker) {
        self.tracker = tracker
    }

    @MainActor public var dispatchingKey: InputLatencyToken? { tracker.dispatchingKey }

    // perf-hot: 0.05us terminal-key
    public func terminalEcho(_ token: InputLatencyToken, _ event: TerminalEchoEvent, at nanos: UInt64) {
        switch event {
        case .echoParsed:
            tracker.mark(token, .echoParsed, at: nanos)
        case .contentSubmitted:
            if tracker.mark(token, .contentSubmitted, at: nanos) { tracker.markCausedFrameUpdate(token) }
        case .noEcho, .noFrame, .superseded, .surfaceClosed:
            break
        }
    }

    public func keyEchoStamped(flow: UInt64, _ stamps: TerminalKeyStamps, decodedAt: UInt64) {
        tracker.keyEchoStamped(flow: flow, stamps, decodedAt: decodedAt)
    }
}
