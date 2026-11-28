public import CMUXMobileCore

/// Authenticated broker operations used by the relay policy service.
public protocol CmxIrohRelayPolicyServing: Sendable {
    /// Issues endpoint-scoped relay bootstrap material.
    func issueRelayBootstrap(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse

    /// Fetches the current account relay preference.
    func relayPreference() async throws -> CmxIrohRelayPreferenceResponse

    /// Replaces the account relay preference using optimistic concurrency.
    func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse
}
