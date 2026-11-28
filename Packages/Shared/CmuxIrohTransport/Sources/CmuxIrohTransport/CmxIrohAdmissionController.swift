public import CMUXMobileCore
public import Foundation

/// Mac admission policy combining online grants, offline sessions, and local revoke state.
public actor CmxIrohAdmissionController: CmxIrohAdmissionAuthorizing {
    private let offlineSessions: CmxIrohOfflinePairingSessions
    private let onlineRegistry: CmxIrohOnlineAdmissionRegistry
    private let now: @Sendable () -> Date
    private var acceptor: CmxIrohGrantPeer
    private var pairingEnabled: Bool
    private var revokedBindingIDs: Set<String> = []
    private var policyRevision: UInt64 = 0
    private var policyMutationCount = 0

    public init(
        acceptor: CmxIrohGrantPeer,
        pairingEnabled: Bool,
        offlineSessions: CmxIrohOfflinePairingSessions,
        onlineRegistry: CmxIrohOnlineAdmissionRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.acceptor = acceptor
        self.pairingEnabled = pairingEnabled
        self.offlineSessions = offlineSessions
        self.onlineRegistry = onlineRegistry
        self.now = now
    }

    /// Atomically replaces authenticated broker policy after a registry refresh.
    public func update(
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohGrantPeer,
        pairingEnabled: Bool
    ) async {
        beginPolicyMutation()
        defer { endPolicyMutation() }
        await onlineRegistry.update(keys: keys, acceptor: acceptor)
        await offlineSessions.setPairingEnabled(pairingEnabled)
        self.acceptor = acceptor
        self.pairingEnabled = pairingEnabled
    }

    /// Replaces the root-verified managed fleet without restarting admission.
    func updateManagedRelayURLs(_ relayURLs: Set<String>) async {
        beginPolicyMutation()
        defer { endPolicyMutation() }
        await onlineRegistry.updateManagedRelayURLs(relayURLs)
    }

    /// Applies local revoke before the backend round trip completes.
    public func revoke(bindingID: String) async {
        beginPolicyMutation()
        defer { endPolicyMutation() }
        revokedBindingIDs.insert(bindingID)
        await offlineSessions.revoke(bindingID: bindingID)
        await onlineRegistry.revoke(bindingID: bindingID)
    }

    public func authorize(
        credential: CmxIrohAdmissionCredential,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohAdmissionAuthorization {
        guard policyMutationCount == 0,
              pairingEnabled,
              acceptor.platform == .mac,
              !revokedBindingIDs.contains(acceptor.bindingID) else {
            return .denied(code: 1)
        }
        let revision = policyRevision
        do {
            switch credential.kind {
            case .pairGrant:
                guard let token = credential.pairGrantToken else {
                    return .denied(code: 1)
                }
                switch await onlineRegistry.authorizePairGrant(
                    token,
                    authenticatedPeerID: authenticatedPeerID
                ) {
                case let .accepted(lease):
                    return checkedAuthorization(lease, revision: revision)
                case .denied:
                    return .denied(code: 1)
                }
            case .offlinePairing:
                let pair = try await offlineSessions.verifyAndConsume(
                    credential: credential,
                    authenticatedPeerID: authenticatedPeerID,
                    now: now()
                )
                guard policyMutationCount == 0, policyRevision == revision else {
                    return .denied(code: 1)
                }
                switch await onlineRegistry.authorizeOfflinePair(pair) {
                case let .accepted(lease):
                    return checkedAuthorization(lease, revision: revision)
                case .denied:
                    return .denied(code: 1)
                }
            }
        } catch {
            return .denied(code: 1)
        }
    }

    private func checkedAuthorization(
        _ lease: CmxIrohOnlineAdmissionLease,
        revision: UInt64
    ) -> CmxIrohAdmissionAuthorization {
        guard policyMutationCount == 0,
              policyRevision == revision,
              !revokedBindingIDs.contains(lease.peer.bindingID),
              !revokedBindingIDs.contains(acceptor.bindingID) else {
            return .denied(code: 1)
        }
        return .accepted(lease.peer, onlineLease: lease)
    }

    private func beginPolicyMutation() {
        policyRevision &+= 1
        policyMutationCount += 1
    }

    private func endPolicyMutation() {
        policyMutationCount -= 1
    }
}
