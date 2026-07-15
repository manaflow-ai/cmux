/// The store's view of the daemon's reachability.
public enum SubrouterDaemonState: Sendable, Equatable {
    /// No probe has run yet (integration just enabled or app just started).
    case unknown
    /// The daemon answered its last request.
    case healthy
    /// The daemon failed the last `consecutiveFailures` requests; the store
    /// probes `/_subrouter/health` on an exponential backoff while any
    /// subrouter UI is visible, and goes fully idle otherwise.
    case unreachable(consecutiveFailures: Int)

    /// Whether the daemon answered its last request.
    public var isHealthy: Bool {
        self == .healthy
    }
}
