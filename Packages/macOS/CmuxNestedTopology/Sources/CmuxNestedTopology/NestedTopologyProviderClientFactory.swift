/// Creates provider clients for attachment attempts.
///
/// Kept injectable so unit tests can stub handshake/snapshot without a live socket
/// while production uses ``HerdrNestedTopologyClientFactory``.
public protocol NestedTopologyProviderClientFactory: Sendable {
    /// Creates a client for the given Herdr configuration.
    ///
    /// PR3 only wires the Herdr adapter. Future providers can broaden this factory.
    func makeHerdrClient(
        configuration: HerdrNestedTopologyClientConfiguration
    ) -> any NestedTopologyProviderClient
}

/// Production factory that returns ``HerdrNestedTopologyClient``.
public struct HerdrNestedTopologyClientFactory: NestedTopologyProviderClientFactory, Sendable {
    public init() {}

    public func makeHerdrClient(
        configuration: HerdrNestedTopologyClientConfiguration
    ) -> any NestedTopologyProviderClient {
        HerdrNestedTopologyClient(configuration: configuration)
    }
}
