/// Narrow trust-broker boundary required to resolve one authenticated dial.
public protocol CmxIrohRegistryServing: CmxIrohDiscoveryServing {
    /// Issues a grant for one exact iOS initiator and Mac acceptor binding.
    func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) async throws -> CmxIrohPairGrantResponse
}

extension CmxIrohTrustBrokerClient: CmxIrohRegistryServing {}
