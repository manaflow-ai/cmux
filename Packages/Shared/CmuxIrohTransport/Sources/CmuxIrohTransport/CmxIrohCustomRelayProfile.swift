/// A strict user-controlled relay override that excludes every managed provider.
public struct CmxIrohCustomRelayProfile: Equatable, Sendable {
    /// The complete custom relay set used when Iroh needs relay assistance.
    public let relays: [CmxIrohCustomRelay]

    /// Creates a bounded custom relay override.
    ///
    /// - Parameter relays: Between one and sixteen unique custom relay origins.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidSelection`` for an invalid set.
    public init(relays: [CmxIrohCustomRelay]) throws {
        guard (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(relays.count),
              Set(relays.map(\.url)).count == relays.count else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        self.relays = relays
    }
}
