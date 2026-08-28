/// Authenticated broker operations used by the relay policy service.
public protocol CmxIrohRelayPolicyServing: Sendable {
    /// Fetches the signed managed relay policy and account preference.
    func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse

    /// Fetches the current account relay preference.
    func relayPreference() async throws -> CmxIrohRelayPreferenceResponse

    /// Replaces the account relay preference using optimistic concurrency.
    func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse
}
