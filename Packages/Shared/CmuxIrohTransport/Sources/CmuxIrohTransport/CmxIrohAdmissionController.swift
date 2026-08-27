public import CMUXMobileCore
public import Foundation

/// Mac admission policy combining online grants, offline sessions, the paired
/// endpoint allowlist, and local revoke state.
public actor CmxIrohAdmissionController: CmxIrohAdmissionAuthorizing {
    private let offlineSessions: CmxIrohOfflinePairingSessions
    private let onlineRegistry: CmxIrohOnlineAdmissionRegistry
    private let allowlist: CmxIrohPairedPeerAllowlist?
    private let allowlistScope: CmxIrohPairedPeerAllowlistScope?
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
        allowlist: CmxIrohPairedPeerAllowlist? = nil,
        allowlistScope: CmxIrohPairedPeerAllowlistScope? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.acceptor = acceptor
        self.pairingEnabled = pairingEnabled
        self.offlineSessions = offlineSessions
        self.onlineRegistry = onlineRegistry
        self.allowlist = allowlist
        self.allowlistScope = allowlistScope
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
        if let allowlist, let allowlistScope {
            await allowlist.removeEntries(
                bindingID: bindingID,
                scope: allowlistScope
            )
        }
    }

    public func authorize(
        credential: CmxIrohAdmissionCredential?,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohAdmissionAuthorization {
        guard policyMutationCount == 0,
              pairingEnabled,
              acceptor.platform == .mac,
              !revokedBindingIDs.contains(acceptor.bindingID) else {
            return .denied(code: 1)
        }
        let revision = policyRevision
        guard let credential else {
            return await authorizeAllowlistedPeer(
                authenticatedPeerID: authenticatedPeerID,
                revision: revision
            )
        }
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
                    let authorization = checkedAuthorization(lease, revision: revision)
                    await recordVerifiedPairing(lease, authorization: authorization)
                    return authorization
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

    /// Admits a TLS-proven EndpointID directly from the persisted allowlist.
    ///
    /// The entry pins the exact initiator and acceptor tuples the original
    /// verified grant carried. The online registry revalidates both bindings
    /// against this Mac account's authenticated broker view exactly as it does
    /// for an in-band grant, so allowlist admission never bypasses the account
    /// check the grant used to carry. A refusal evicts the entry: the phone's
    /// grant-fetch fallback then re-establishes (or is refused) authority.
    private func authorizeAllowlistedPeer(
        authenticatedPeerID: CmxIrohPeerIdentity,
        revision: UInt64
    ) async -> CmxIrohAdmissionAuthorization {
        guard let allowlist, let allowlistScope else { return .denied(code: 1) }
        guard let entry = await allowlist.entry(
            forInitiatorEndpointID: authenticatedPeerID,
            scope: allowlistScope,
            now: now()
        ) else {
            return .denied(code: 1)
        }
        guard policyMutationCount == 0, policyRevision == revision else {
            return .denied(code: 1)
        }
        guard entry.acceptor == acceptor,
              !revokedBindingIDs.contains(entry.initiator.bindingID) else {
            // The Mac's own binding identity changed since pairing, or the
            // phone binding was locally revoked: the entry is dead.
            await allowlist.removeEntry(
                forInitiatorEndpointID: authenticatedPeerID,
                scope: allowlistScope
            )
            return .denied(code: 1)
        }
        switch await onlineRegistry.authorizePairedEndpoint(
            initiator: entry.initiator,
            acceptor: entry.acceptor,
            expiresAt: entry.expiresAt,
            authenticatedPeerID: authenticatedPeerID
        ) {
        case let .accepted(lease):
            return checkedAuthorization(lease, revision: revision)
        case .denied:
            // Definitive local or registry refusal (revoked, unpaired,
            // expired). Evict so a stale entry cannot be retried forever;
            // the bootstrap grant path remains the recovery route.
            await allowlist.removeEntry(
                forInitiatorEndpointID: authenticatedPeerID,
                scope: allowlistScope
            )
            return .denied(code: 1)
        }
    }

    /// Persists the paired endpoint after its grant verified, bounded by the
    /// grant's own signed expiry. Recording failure only costs the fast path.
    private func recordVerifiedPairing(
        _ lease: CmxIrohOnlineAdmissionLease,
        authorization: CmxIrohAdmissionAuthorization
    ) async {
        guard case .accepted = authorization,
              let allowlist,
              let allowlistScope,
              case let .pairGrant(_, initiator, grantAcceptor) = lease.authority else {
            return
        }
        let clock = now()
        await allowlist.record(
            CmxIrohPairedPeerAllowlistEntry(
                initiator: initiator,
                acceptor: grantAcceptor,
                expiresAt: lease.expiresAt,
                recordedAt: clock
            ),
            scope: allowlistScope,
            now: clock
        )
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
