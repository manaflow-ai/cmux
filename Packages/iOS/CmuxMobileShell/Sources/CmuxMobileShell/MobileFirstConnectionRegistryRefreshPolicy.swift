/// Renewal timing for account-private live sessions in the team device registry.
public struct MobileFirstConnectionRegistryRefreshPolicy: Equatable, Sendable {
    /// Delay between completed renewal attempts.
    public let refreshInterval: Duration

    /// Creates a renewal policy.
    ///
    /// The Mac renews every 60 seconds and the service lease lasts 120 seconds.
    /// The 40-second default leaves margin for network and scheduling delays.
    /// - Parameter refreshInterval: Delay before each registry renewal.
    public init(refreshInterval: Duration = .seconds(40)) {
        self.refreshInterval = refreshInterval
    }
}
