/// Trust-broker operations required by a Mac host runtime.
public protocol CmxIrohHostBrokerServing: CmxIrohDiscoveryServing,
    CmxIrohRelayTokenServing, CmxIrohBindingRevoking
{
    /// Checks a caller-owned broker floor without performing network work.
    func preflight(operation: CmxIrohBrokerOperation) async throws

    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse
}

public extension CmxIrohHostBrokerServing {
    func preflight(operation _: CmxIrohBrokerOperation) async throws {}
}

extension CmxIrohTrustBrokerClient: CmxIrohHostBrokerServing {}
