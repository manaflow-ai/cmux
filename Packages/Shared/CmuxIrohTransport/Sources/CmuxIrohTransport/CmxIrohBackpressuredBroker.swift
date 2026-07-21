public import CMUXMobileCore

/// Operation-gated client broker used by an account-owned runtime.
public struct CmxIrohBackpressuredClientBroker: CmxIrohClientBrokerServing, Sendable {
    private let broker: any CmxIrohClientBrokerServing
    private let gate: CmxIrohBrokerBackpressureGate
    private let accountID: String

    public init(
        broker: any CmxIrohClientBrokerServing,
        gate: CmxIrohBrokerBackpressureGate,
        accountID: String
    ) {
        self.broker = broker
        self.gate = gate
        self.accountID = accountID
    }

    public func preflight(operation: CmxIrohBrokerOperation) async throws {
        try await gate.preflight(accountID: accountID, operation: operation)
    }

    public func register(
        prepared: CmxIrohPreparedRegistration,
        signer: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        try await gate.perform(
            accountID: accountID,
            operation: .registration
        ) {
            try await broker.register(prepared: prepared, signer: signer)
        }
    }

    public func discover() async throws -> CmxIrohDiscoveryResponse {
        try await gate.perform(accountID: accountID, operation: .discovery) {
            try await broker.discover()
        }
    }

    public func issuePairGrant(
        initiatorBindingID: String,
        acceptorBindingID: String
    ) async throws -> CmxIrohPairGrantResponse {
        try await gate.perform(accountID: accountID, operation: .pairGrant) {
            try await broker.issuePairGrant(
                initiatorBindingID: initiatorBindingID,
                acceptorBindingID: acceptorBindingID
            )
        }
    }

    public func issueRelayToken(
        bindingID: String,
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayTokenResponse {
        try await gate.perform(accountID: accountID, operation: .relayCredential) {
            try await broker.issueRelayToken(
                bindingID: bindingID,
                endpointID: endpointID
            )
        }
    }

    public func revoke(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.revoke(bindingID: bindingID)
        }
    }
}

/// Operation-gated relay-policy broker sharing a runtime's account gate.
public struct CmxIrohBackpressuredRelayPolicyBroker: CmxIrohRelayPolicyServing, Sendable {
    private let broker: any CmxIrohRelayPolicyServing
    private let gate: CmxIrohBrokerBackpressureGate
    private let accountID: String

    public init(
        broker: any CmxIrohRelayPolicyServing,
        gate: CmxIrohBrokerBackpressureGate,
        accountID: String
    ) {
        self.broker = broker
        self.gate = gate
        self.accountID = accountID
    }

    public func issueRelayBootstrap(
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        try await gate.perform(accountID: accountID, operation: .relayCredential) {
            try await broker.issueRelayBootstrap(endpointID: endpointID)
        }
    }

    public func relayPreference() async throws -> CmxIrohRelayPreferenceResponse {
        try await gate.perform(accountID: accountID, operation: .relayPreference) {
            try await broker.relayPreference()
        }
    }

    public func updateRelayPreference(
        _ request: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        try await gate.perform(accountID: accountID, operation: .relayPreference) {
            try await broker.updateRelayPreference(request)
        }
    }
}
