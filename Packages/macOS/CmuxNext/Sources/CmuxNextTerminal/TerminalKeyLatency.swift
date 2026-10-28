public import CmuxNextInput
public import CmuxNextInputCore

/// The app's input latency tracker as the terminals' echo stages see it (p04-input-006 and the app half of
/// p04-input-094): the composition root installs it before the first terminal (``TerminalEchoStages/install(_:)``), so
/// a terminal key's slot gets `contentSubmitted` (the first frame Ghostty hands its layer after the key's echo) and then
/// its `presented` estimate. Without it a terminal key slot closed at its deadline with no presented stage, so no
/// terminal key-to-echo-frame time existed (first-seconds-evidence.md step 2).
///
/// - ``dispatchingKey`` is the key slot `sendEvent` is dispatching: a surface arms its echo on it.
/// - ``terminalEcho(_:_:at:)`` stamps `contentSubmitted` (which also marks the slot's frame update). A key that ends with
///   no frame (no echo, a hidden surface, superseded, closed) stamps nothing: its slot closes at the tracker's content
///   deadline.
public nonisolated final class TerminalKeyLatency: TerminalEchoLatencySink {
    private let tracker: InputLatencyTracker

    public init(tracker: InputLatencyTracker) {
        self.tracker = tracker
    }

    @MainActor public var dispatchingKey: InputLatencyToken? { tracker.dispatchingKey }

    // perf-hot: 0.05us terminal-key
    public func terminalEcho(_ token: InputLatencyToken, _ event: TerminalEchoEvent, at nanos: UInt64) {
        switch event {
        case .contentSubmitted:
            if tracker.mark(token, .contentSubmitted, at: nanos) { tracker.markCausedFrameUpdate(token) }
        case .echoParsed, .noEcho, .noFrame, .superseded, .surfaceClosed:
            break
        }
    }
}
