extension SSHConnectionMachine.Status {
    /// What Reconnect does for a link in this status.
    /// `restart`: stop the link client and the daemon connection, then connect with a new retry budget.
    public enum ReconnectStep: Equatable, Sendable { case connect, restart, reconnectDaemon, wake, newAttempt, nothing }

    /// What Reconnect does for a link in this status whose daemon startup is connected
    /// (`daemonConnected`) and whose daemon handshake failed (`daemonFailed`). `retriesSpent`: a later
    /// daemon reconnect spent its timed retries; nothing tries any more, so a wake would try once on the
    /// same link client (HQ #4877 G4).
    public func reconnectStep(daemonConnected: Bool, daemonFailed: Bool, retriesSpent: Bool = false) -> ReconnectStep {
        if retriesSpent, self == .connecting || self == .connected || self == .reconnecting { return .restart }
        switch self {
        case .offline, .unreachable, .failed:
            // These failures leave the gate open for automatic backoff, so a user
            // Retry must start a fresh attempt rather than only waking the loop.
            return .connect
        case .connected:
            // A healthy transport has no reconnect to perform. If only the daemon
            // handshake failed, retry that daemon attempt explicitly; otherwise a
            // plain Reconnect must not arm a timeout on a live connection.
            return daemonFailed ? .reconnectDaemon : .nothing
        case .reconnecting where daemonConnected:
            // A transient interruption under an established daemon connection: the link may
            // recover with its socket and connection intact, and no didConnect would then cancel
            // a new startup deadline. Only wake the link.
            return .wake
        default:
            return .newAttempt
        }
    }
}
