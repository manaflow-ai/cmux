public import Foundation

/// The complete immutable input used to bind one Iroh endpoint generation.
public struct CmxIrohEndpointConfiguration: Equatable, Sendable {
    /// The device-local secret that preserves EndpointID across recreation.
    public let secretKey: CmxIrohSecretKey

    /// The application protocols accepted by this endpoint.
    public let alpns: [Data]

    /// The exact managed relay origins allowed for this build or policy.
    public let managedRelayURLs: Set<String>

    /// Endpoint-scoped credentials for some or all allowed relays.
    public let relays: [CmxIrohRelayConfiguration]

    /// Creates a validated endpoint bind configuration.
    ///
    /// - Parameters:
    ///   - secretKey: The stable endpoint key.
    ///   - alpns: ALPNs advertised by the endpoint.
    ///   - managedRelayURLs: Exact relay origins permitted by app or MDM policy.
    ///   - relays: Current endpoint-scoped relay credentials.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for fleet-policy violations.
    public init(
        secretKey: CmxIrohSecretKey,
        alpns: [Data],
        managedRelayURLs: Set<String>,
        relays: [CmxIrohRelayConfiguration]
    ) throws {
        guard relays.count <= 8 else {
            throw CmxIrohEndpointConfigurationError.tooManyRelays(relays.count)
        }
        var observedURLs = Set<String>()
        for relay in relays {
            guard managedRelayURLs.contains(relay.url) else {
                throw CmxIrohEndpointConfigurationError.unmanagedRelayURL(relay.url)
            }
            guard observedURLs.insert(relay.url).inserted else {
                throw CmxIrohEndpointConfigurationError.duplicateRelayURL(relay.url)
            }
        }
        self.secretKey = secretKey
        self.alpns = alpns
        self.managedRelayURLs = managedRelayURLs
        self.relays = relays
    }
}
