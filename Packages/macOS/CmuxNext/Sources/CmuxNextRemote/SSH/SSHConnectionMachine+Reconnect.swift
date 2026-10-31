extension SSHConnectionMachine.Status {
    /// What Reconnect does for a link in this status.
    public enum ReconnectStep: Equatable, Sendable { case connect, reconnectDaemon, wake, newAttempt, nothing }

    /// What Reconnect does for a link in this status whose daemon startup is connected
    /// (`daemonConnected`) and whose daemon handshake failed (`daemonFailed`).
    public func reconnectStep(daemonConnected: Bool, daemonFailed: Bool) -> ReconnectStep {
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
