/// Trust-broker operations required by an iOS Iroh client runtime.
public protocol CmxIrohClientBrokerServing: CmxIrohRegistryServing, CmxIrohRelayTokenServing {
    /// Registers an endpoint using its challenge-bound identity proof.
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    /// Revokes one broker binding after local sign-out teardown has completed.
    func revoke(bindingID: String) async throws
}

extension CmxIrohTrustBrokerClient: CmxIrohClientBrokerServing {}
