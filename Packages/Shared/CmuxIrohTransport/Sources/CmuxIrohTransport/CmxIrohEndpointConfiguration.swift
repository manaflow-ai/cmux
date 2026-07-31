public import Foundation

/// The complete immutable input used to bind one Iroh endpoint generation.
public struct CmxIrohEndpointConfiguration: Equatable, Sendable {
    /// The device-local secret that preserves EndpointID across recreation.
    public let secretKey: CmxIrohSecretKey

    /// The application protocols accepted by this endpoint.
    public let alpns: [Data]

    /// The endpoint's local UDP socket policy.
    public let bindPolicy: CmxIrohEndpointBindPolicy

    /// The exact relay policy used by this endpoint generation.
    public let relayProfile: CmxIrohEndpointRelayProfile

    /// The exact managed relay origins allowed for this build or policy.
    public var managedRelayURLs: Set<String> {
        relayProfile.source == .managed ? relayProfile.allowedRelayURLs : []
    }

    /// Endpoint-scoped credentials for some or all allowed relays.
    public var relays: [CmxIrohRelayConfiguration] {
        relayProfile.managedRelays
    }

    /// Creates a validated endpoint bind configuration.
    ///
    /// - Parameters:
    ///   - secretKey: The stable endpoint key.
    ///   - alpns: ALPNs advertised by the endpoint.
    ///   - bindPolicy: Ephemeral by default, or an exact required socket address.
    ///   - managedRelayURLs: Exact relay origins permitted by app or MDM policy.
    ///   - relays: Current endpoint-scoped relay credentials.
    /// - Throws: ``CmxIrohEndpointConfigurationError`` for fleet-policy violations.
    public init(
        secretKey: CmxIrohSecretKey,
        alpns: [Data],
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        managedRelayURLs: Set<String>,
        relays: [CmxIrohRelayConfiguration]
    ) throws {
        let relayProfile = try CmxIrohEndpointRelayProfile(
            managedRelayURLs: managedRelayURLs,
            relays: relays
        )
        self.secretKey = secretKey
        self.alpns = alpns
        self.bindPolicy = bindPolicy
        self.relayProfile = relayProfile
    }

    /// Creates an endpoint with an already validated relay profile.
    ///
    /// - Parameters:
    ///   - secretKey: The stable endpoint key.
    ///   - alpns: ALPNs advertised by the endpoint.
    ///   - bindPolicy: Ephemeral by default, or an exact required socket address.
    ///   - relayProfile: The complete managed or custom relay policy.
    public init(
        secretKey: CmxIrohSecretKey,
        alpns: [Data],
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        relayProfile: CmxIrohEndpointRelayProfile
    ) {
        self.secretKey = secretKey
        self.alpns = alpns
        self.bindPolicy = bindPolicy
        self.relayProfile = relayProfile
    }
}
