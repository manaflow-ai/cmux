/// Trust-broker operations required by an iOS Iroh client runtime.
public protocol CmxIrohClientBrokerServing: CmxIrohRegistryServing,
    CmxIrohRelayTokenServing, CmxIrohBindingRevoking
{
    /// Registers an endpoint using its challenge-bound identity proof.
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse
}

extension CmxIrohTrustBrokerClient: CmxIrohClientBrokerServing {}
