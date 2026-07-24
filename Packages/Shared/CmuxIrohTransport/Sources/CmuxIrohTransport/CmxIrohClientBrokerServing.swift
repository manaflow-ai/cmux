/// Trust-broker operations required by an iOS Iroh client runtime.
public protocol CmxIrohClientBrokerServing: CmxIrohRegistryServing,
    CmxIrohRelayTokenServing, CmxIrohBindingRevoking
{
    /// Checks a caller-owned broker floor without performing network work.
    func preflight(operation: CmxIrohBrokerOperation) async throws

    /// Registers an endpoint using its challenge-bound identity proof.
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse
}

public extension CmxIrohClientBrokerServing {
    func preflight(operation _: CmxIrohBrokerOperation) async throws {}
}

extension CmxIrohTrustBrokerClient: CmxIrohClientBrokerServing {}
