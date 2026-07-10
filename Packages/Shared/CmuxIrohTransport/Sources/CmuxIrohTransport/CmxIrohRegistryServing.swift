/// Narrow trust-broker boundary required to resolve one authenticated dial.
public protocol CmxIrohRegistryServing: Sendable {
    /// Returns the current same-account endpoint registry and verification keys.
    func discover() async throws -> CmxIrohDiscoveryResponse

    /// Issues a grant for one exact iOS initiator and Mac acceptor binding.
    func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) async throws -> CmxIrohPairGrantResponse
}

extension CmxIrohTrustBrokerClient: CmxIrohRegistryServing {}
