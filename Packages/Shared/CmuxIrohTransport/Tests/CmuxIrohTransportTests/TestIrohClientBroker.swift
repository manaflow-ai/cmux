@testable import CmuxIrohTransport

actor TestIrohClientBroker: CmxIrohClientBrokerServing {
    private let registration: CmxIrohRegistrationResponse
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let relayResponse: CmxIrohRelayTokenResponse
    private let revokeError: (any Error)?
    private var preparedRegistrations: [CmxIrohPreparedRegistration] = []
    private var revokedBindingIDs: [String] = []

    init(
        binding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        relay: CmxIrohRelayTokenResponse,
        issueRelayAtRegistration: Bool = true,
        revokeError: (any Error)? = nil
    ) {
        registration = CmxIrohRegistrationResponse(
            binding: binding,
            relay: issueRelayAtRegistration ? .issued(relay) : .unavailable
        )
        discoveryResponse = discovery
        relayResponse = relay
        self.revokeError = revokeError
    }

    func register(
        prepared: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) -> CmxIrohRegistrationResponse {
        preparedRegistrations.append(prepared)
        return registration
    }

    func discover() -> CmxIrohDiscoveryResponse {
        discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(bindingID _: String) -> CmxIrohRelayTokenResponse {
        relayResponse
    }

    func revoke(bindingID: String) throws {
        revokedBindingIDs.append(bindingID)
        if let revokeError { throw revokeError }
    }

    func observedRegistrations() -> [CmxIrohPreparedRegistration] {
        preparedRegistrations
    }

    func observedRevokedBindingIDs() -> [String] {
        revokedBindingIDs
    }
}
