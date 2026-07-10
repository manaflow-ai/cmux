@testable import CmuxIrohTransport

actor TestIrohClientBroker: CmxIrohClientBrokerServing {
    private let registration: CmxIrohRegistrationResponse
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let relayResponse: CmxIrohRelayTokenResponse
    private let revokeError: (any Error)?
    private var registrationError: (any Error)?
    private var preparedRegistrations: [CmxIrohPreparedRegistration] = []
    private var revokedBindingIDs: [String] = []

    init(
        binding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        relay: CmxIrohRelayTokenResponse,
        issueRelayAtRegistration: Bool = true,
        registrationError: (any Error)? = nil,
        revokeError: (any Error)? = nil
    ) {
        registration = CmxIrohRegistrationResponse(
            binding: binding,
            relay: issueRelayAtRegistration ? .issued(relay) : .unavailable
        )
        discoveryResponse = discovery
        relayResponse = relay
        self.revokeError = revokeError
        self.registrationError = registrationError
    }

    func register(
        prepared: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) throws -> CmxIrohRegistrationResponse {
        preparedRegistrations.append(prepared)
        if let registrationError { throw registrationError }
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

    func setRegistrationError(_ error: (any Error)?) {
        registrationError = error
    }
}
