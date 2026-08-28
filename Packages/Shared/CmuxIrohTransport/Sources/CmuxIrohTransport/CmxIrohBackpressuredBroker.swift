public import CMUXMobileCore

/// Operation-gated client broker used by an account-owned runtime.
public struct CmxIrohBackpressuredClientBroker:
    CmxIrohClientBrokerServing,
    CmxConnectivityAuthorityServing,
    Sendable
{
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

    /// Reports whether the wrapped client retains request authorization.
    public func hasBindingAuthorization() async -> Bool {
        await broker.hasBindingAuthorization()
    }

    /// Returns the binding ID represented by the wrapped client's proof.
    public func bindingAuthorizationID() async -> String? {
        await broker.bindingAuthorizationID()
    }

    public func discover() async throws -> CmxIrohDiscoveryResponse {
        try await gate.perform(accountID: accountID, operation: .discovery) {
            try await broker.discover()
        }
    }

    public func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        try await gate.perform(accountID: accountID, operation: .discovery) {
            try await CmxAuthoritativeDiscoveryResolver(
                broker: broker
            ).sync(knownRevision: knownRevision)
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

    public func revoke(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.revoke(bindingID: bindingID)
        }
    }

    /// Revokes an older same-device binding through the wrapped stale route.
    public func revokeStale(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.revokeStale(bindingID: bindingID)
        }
    }

    /// Revokes one same-build Mac through the wrapped account-management path.
    public func forgetMac(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.forgetMac(bindingID: bindingID)
        }
    }
}

/// Operation-gated host broker used by an account-owned Mac runtime.
public struct CmxIrohBackpressuredHostBroker:
    CmxIrohHostBrokerServing,
    CmxConnectivityAuthorityServing,
    Sendable
{
    private let broker: any CmxIrohHostBrokerServing
    private let gate: CmxIrohBrokerBackpressureGate
    private let accountID: String

    public init(
        broker: any CmxIrohHostBrokerServing,
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
        try await gate.perform(accountID: accountID, operation: .registration) {
            try await broker.register(prepared: prepared, signer: signer)
        }
    }

    public func discover() async throws -> CmxIrohDiscoveryResponse {
        try await gate.perform(accountID: accountID, operation: .discovery) {
            try await broker.discover()
        }
    }

    public func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        try await gate.perform(accountID: accountID, operation: .discovery) {
            try await CmxAuthoritativeDiscoveryResolver(
                broker: broker
            ).sync(knownRevision: knownRevision)
        }
    }

    public func issueEndpointAttestation(
        bindingID: String
    ) async throws -> CmxIrohEndpointAttestationResponse {
        try await gate.perform(
            accountID: accountID,
            operation: .endpointAttestation
        ) {
            try await broker.issueEndpointAttestation(bindingID: bindingID)
        }
    }

    public func revoke(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.revoke(bindingID: bindingID)
        }
    }

    /// Revokes an older same-device binding through the wrapped stale route.
    public func revokeStale(bindingID: String) async throws {
        try await gate.perform(accountID: accountID, operation: .revocation) {
            try await broker.revokeStale(bindingID: bindingID)
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

    /// Fetches the signed relay policy through the shared account gate.
    public func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse {
        try await gate.perform(accountID: accountID, operation: .relayCredential) {
            try await broker.fetchRelayPolicy()
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
