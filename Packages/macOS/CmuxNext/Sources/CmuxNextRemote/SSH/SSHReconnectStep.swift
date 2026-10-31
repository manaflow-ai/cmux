/// What Reconnect does for an SSH machine whose link is in `link`, given how its daemon
/// connection stands (`SSHService.reconnect` runs it).
public enum SSHReconnectStep: Equatable, Sendable {
    /// Connect again (the link's gate opens, the daemon loop wakes).
    case connect
    /// Stop the link client and the daemon connection, then connect with a new retry budget.
    case restart
    /// Retry the daemon handshake on a connected link.
    case reconnectDaemon
    /// Wake the link only.
    case wake
    /// Stamp a new attempt, then wake the link.
    case newAttempt
    case nothing

    /// - Parameters:
    ///   - daemonStarted: the daemon's first connect finished (`DaemonStartupState.connected`).
    ///   - daemonFailed: the daemon gave up after SSH reached the machine.
    ///   - retriesSpent: a later daemon reconnect spent its timed retries; nothing tries any
    ///     more, so a wake would try once on the same link client (HQ #4877 G4).
    public init(link: SSHConnectionMachine.Status, daemonStarted: Bool, daemonFailed: Bool, retriesSpent: Bool = false) {
        if retriesSpent, link == .connecting || link == .connected || link == .reconnecting {
            self = .restart
            return
        }
        switch link {
        case .offline, .unreachable, .failed:
            // These failures leave the gate open for automatic backoff, so a user
            // Retry must start a fresh attempt rather than only waking the loop.
            self = .connect
        case .connected:
            // A healthy transport has no reconnect to perform. If only the daemon
            // handshake failed, retry that daemon attempt explicitly; otherwise a
            // plain Reconnect must not arm a timeout on a live connection.
            self = daemonFailed ? .reconnectDaemon : .nothing
        case .reconnecting where daemonStarted:
            // A transient interruption under an established daemon connection: the link may
            // recover with its socket and connection intact, and no didConnect would then cancel
            // a new startup deadline. Only wake the link.
            self = .wake
        default:
            self = .newAttempt
        }
    }
}
