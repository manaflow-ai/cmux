public import CMUXMobileCore

/// Endpoint relay mutations required by the credential coordinator.
public protocol CmxIrohRelayEndpointControlling: Sendable {
    /// Replaces managed relay credentials on the expected endpoint identity.
    func replaceRelays(
        _ relays: [CmxIrohRelayConfiguration],
        expectedIdentity: CmxIrohPeerIdentity
    ) async throws

    /// Replaces the complete relay profile on the expected endpoint identity.
    func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        expectedIdentity: CmxIrohPeerIdentity
    ) async throws
}

extension CmxIrohEndpointSupervisor: CmxIrohRelayEndpointControlling {}
