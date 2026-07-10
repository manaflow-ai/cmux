/// Trust-broker operations required by a Mac host runtime.
public protocol CmxIrohHostBrokerServing: CmxIrohRelayTokenServing {
    func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse

    func discover() async throws -> CmxIrohDiscoveryResponse

    func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse

    func revoke(bindingID: String) async throws
}

extension CmxIrohTrustBrokerClient: CmxIrohHostBrokerServing {}
