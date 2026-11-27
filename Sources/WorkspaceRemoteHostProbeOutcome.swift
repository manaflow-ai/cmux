import Foundation

/// Outcome of a quick reachability probe against the SSH endpoint of a remote
/// workspace, used by the auto-reconnect loop to decide whether retrying makes
/// sense at all.
enum WorkspaceRemoteHostProbeOutcome: Equatable, Sendable {
    /// A TCP connection to the resolved SSH endpoint succeeded.
    case reachable
    /// The endpoint could not be reached (DNS failure, connection refused,
    /// timeout, or no route). The associated reason is a short human-readable
    /// detail for logs and connection-state messages.
    case unreachable(reason: String)
    /// Reachability could not be determined (for example ProxyCommand-based
    /// transports that cannot be probed with a direct TCP connection). The
    /// policy must never suspend the reconnect loop based on this outcome.
    case indeterminate
}
