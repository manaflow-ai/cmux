/// Selects how Mosh discovers the address used for its UDP session.
///
/// Production callers always start from ``remote``; the launcher downgrades
/// to ``proxy`` automatically when SSH advertises an unusable address. The
/// other cases exist so tests can pin each generated mode explicitly.
public enum MoshRemoteIPMode: String, Equatable, Sendable {
    /// Derive the address from the remote SSH connection when possible.
    case remote

    /// Resolve the destination locally before starting the Mosh server.
    case local

    /// Resolve the address through Mosh's local proxy path.
    case proxy
}
