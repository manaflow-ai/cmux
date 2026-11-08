extension SSHConnectionMachine.Status {
    /// What Reconnect does for a link in this status.
    /// Reconnect never restarts a running link client: the link is the only layer that redials, and
    /// it is started again only when its process exited (cmuxterm-hq#7766).
    public enum ReconnectStep: Equatable, Sendable { case connect, reconnectDaemon, wake, newAttempt, nothing }

    /// What Reconnect does for a link in this status whose daemon startup is connected
    /// (`daemonConnected`) and whose daemon handshake failed (`daemonFailed`). `daemonDown`: the
    /// daemon connection dropped and waits for an event; on a connected link a Reconnect retries
    /// that connection once over the same link client (HQ #4877 G4).
    public func reconnectStep(daemonConnected: Bool, daemonFailed: Bool, daemonDown: Bool = false) -> ReconnectStep {
        switch self {
        case .offline, .unreachable, .failed:
            // These failures leave the gate open for automatic backoff, so a user
            // Retry must start a fresh attempt rather than only waking the loop.
            return .connect
        case .connected:
            // A healthy transport has no reconnect to perform. If only the daemon
            // handshake failed, retry that daemon attempt explicitly; otherwise a
            // plain Reconnect must not arm a timeout on a live connection.
            return daemonFailed || daemonDown ? .reconnectDaemon : .nothing
        case .reconnecting where daemonConnected:
            // A transient interruption under an established daemon connection: the link may
            // recover with its socket and connection intact, and no didConnect would then cancel
            // a new startup deadline. Only wake the link.
            return .wake
        default:
            return .newAttempt
        }
    }

    /// Whether the link reaching this status may let the daemon connection's waiting attempt succeed:
    /// the link reports connected again, or its process exited (`.linkLost`), so the next attempt's
    /// ``SSHMachineLink/socketPath()`` starts it once more. The link is the only layer that redials
    /// (cmuxterm-hq#7766); the daemon connection waits for this instead of a timer.
    public func wakesDaemon(after previous: SSHConnectionMachine.Status) -> Bool {
        switch self {
        case .connected: true
        case .connecting: previous == .connected || previous == .reconnecting
        default: false
        }
    }
}
