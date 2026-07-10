/// Narrow trust-broker boundary used by relay credential rotation.
public protocol CmxIrohRelayTokenServing: Sendable {
    /// Issues a fresh endpoint-bound credential for the managed relay fleet.
    func issueRelayToken(bindingID: String) async throws -> CmxIrohRelayTokenResponse
}

extension CmxIrohTrustBrokerClient: CmxIrohRelayTokenServing {}
