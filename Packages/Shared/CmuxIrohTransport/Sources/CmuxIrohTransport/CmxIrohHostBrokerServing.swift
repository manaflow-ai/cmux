/// Trust-broker operations required by a Mac host runtime.
public protocol CmxIrohHostBrokerServing: CmxIrohDiscoveryServing,
    CmxIrohRelayTokenServing, CmxIrohBindingRevoking
{
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse
}

extension CmxIrohTrustBrokerClient: CmxIrohHostBrokerServing {}
