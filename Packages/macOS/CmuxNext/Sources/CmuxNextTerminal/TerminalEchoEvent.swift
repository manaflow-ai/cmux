public import CmuxNextInputCore

/// What happened to a terminal key's echo (``TerminalEchoStage``). Every armed key gets exactly one
/// ending event: ``contentSubmitted`` or one of the misses, after ``echoParsed`` when its output was
/// parsed.
public nonisolated enum TerminalEchoEvent: UInt8, Sendable, Hashable, CaseIterable {
    /// The first output chunk that reached the surface's output lane after the key was parsed there.
    /// Every key waiting then takes the same chunk, as Chromium gives events coalesced into one frame
    /// that frame (cc/metrics/compositor_frame_reporter.cc).
    case echoParsed
    /// The first frame Ghostty handed to its layer after that parse (``InputStage/contentSubmitted``).
    case contentSubmitted
    /// No output within ``TerminalEchoStage/window`` of the key.
    case noEcho
    /// Output was parsed, but no frame was set within the window (the surface was hidden or paused).
    case noFrame
    /// The surface's ring was full (``TerminalEchoStage/defaultCapacity`` keys waiting) and a newer
    /// key took this one's entry.
    case superseded
    /// The surface closed while the key waited.
    case surfaceClosed
}

/// Where a terminal's key-to-echo stages go: the app's input latency tracker, installed at the
/// composition root by p04-input-094 (``TerminalEchoStages/install(_:)``). The terminal reports
/// times and outcomes; the sink owns the latency slots (Chromium's `EventMetrics` takes each stage's
/// time on the thread that saw it, cc/metrics/event_metrics.h).
public nonisolated protocol TerminalEchoLatencySink: AnyObject, Sendable {
    /// The open latency slot of the key event the app is dispatching now, or nil when it tracks none.
    @MainActor var dispatchingKey: InputLatencyToken? { get }

    /// `event` happened to the key `token` names, at `nanos` (`CLOCK_UPTIME_RAW`). Called from any
    /// thread (the output lane, the thread that sets the layer's contents, the deadline's); it must
    /// not block.
    func terminalEcho(_ token: InputLatencyToken, _ event: TerminalEchoEvent, at nanos: UInt64)
}
