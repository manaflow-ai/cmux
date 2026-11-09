import CmuxNextCompat

/// What the daemon connection tells app health (the shared health contract, part `acpmux`): a request
/// that got no reply in time, and the first reply after one. Read-only facts; the timeout and
/// reconnect rules stay the connection's and `DaemonRecovery`'s. A dead or hung daemon shows as "not
/// answering" at the first timed-out request instead of after the heartbeat's misses.
extension DaemonConnection {
    public enum RequestHealth: Sendable, Equatable {
        /// A request ended in `DaemonError.timedOut` (the first since the last answer).
        case timedOut
        /// A request was answered after a timeout.
        case answered
    }

    private struct RequestHealthState: Sendable {
        var sink: @Sendable (RequestHealth) -> Void = { _ in }
        var timedOut = false
    }

    private static let requestHealthState = Mutex(RequestHealthState())

    /// Receives ``RequestHealth`` changes of every connection, on the requester's thread. The App sets
    /// it once at launch to its app health feed; the default drops them.
    public static var requestHealth: @Sendable (RequestHealth) -> Void {
        get { requestHealthState.withLock { $0.sink } }
        set { requestHealthState.withLock { $0.sink = newValue } }
    }

    /// One request's end: only a change (the first timeout, the first answer after it) reaches the sink.
    static func noteRequest(timedOut: Bool) {
        let sink: (@Sendable (RequestHealth) -> Void)? = requestHealthState.withLock { state in
            guard state.timedOut != timedOut else { return nil }
            state.timedOut = timedOut
            return state.sink
        }
        sink?(timedOut ? .timedOut : .answered)
    }
}
