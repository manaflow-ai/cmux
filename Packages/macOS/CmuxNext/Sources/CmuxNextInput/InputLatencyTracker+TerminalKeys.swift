public import CmuxNextInputCore
public import CmuxNextWakeups

/// A terminal key's stages outside the app. The key's slot goes to the daemon as the `flow` of its
/// `send` (``CmuxNextInputCore/InputLatencyToken/keyFlow``); the daemon stamps when it received the key, wrote it to the
/// PTY and read its echo, and sends those times with the echo. Chromium's `EventMetrics` takes each dispatch stage's
/// time in the process that saw it (cc/metrics/event_metrics.h); here the daemon's times come back with the echo.
extension InputLatencyTracker {
    /// Stamps `daemonReceived`, `ptyWritten`, `echoRead` and `echoSent` of the key slot `flow` names, from the
    /// attachment's reader thread. Refused (nothing stamped) when `flow` is not a slot's, the slot closed, or the
    /// stamps are not in order between the key's dispatch and the echo's decode: a daemon whose clock is not this
    /// Mac's.
    ///
    /// - Parameters:
    ///   - flow: The flow the key's `send` carried.
    ///   - stamps: The daemon's times (`CLOCK_UPTIME_RAW`).
    ///   - decodedAt: When the app decoded the echo (`CLOCK_UPTIME_RAW`).
    /// - Returns: Whether the slot took the stamps.
    // perf-hot: 0.05us terminal-key
    @discardableResult
    public nonisolated func keyEchoStamped(flow: UInt64, _ stamps: TerminalKeyStamps, decodedAt: UInt64) -> Bool {
        guard let token = InputLatencyToken(keyFlow: flow), let start = table.time(token, .dispatchStart),
              stamps.isOrdered(after: start, before: decodedAt)
        else { return false }
        table.mark(token, .daemonReceived, at: stamps.received)
        table.mark(token, .ptyWritten, at: stamps.written)
        table.mark(token, .echoRead, at: stamps.read)
        table.mark(token, .echoSent, at: stamps.sent)
        return true
    }
}
