/// Connectivity edges observed by an ``AgentSyncTransport``.
public enum AgentSyncConnectionEvent: Hashable, Sendable {
    /// The transport is available for RPC and event subscription.
    case up
    /// The transport is unavailable.
    case down(reason: String)
    /// The underlying transport was replaced and all subscriptions should be rebuilt.
    case reset
}
