/// Validation failures for connectivity discovery scopes.
public enum CmxConnectivityDiscoveryScopeError: Error, Equatable, Sendable {
    /// The scope contains an invalid identity, tag, platform pair, or peer selector.
    case invalidScope
}
