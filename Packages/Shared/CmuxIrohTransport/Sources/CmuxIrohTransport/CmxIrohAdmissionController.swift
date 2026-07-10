public import CMUXMobileCore
public import Foundation

/// Mac admission policy combining online grants, offline sessions, and local revoke state.
public actor CmxIrohAdmissionController: CmxIrohAdmissionAuthorizing {
    private let verifier: CmxIrohGrantVerifier
    private let offlineSessions: CmxIrohOfflinePairingSessions
    private let onlineRegistry: CmxIrohOnlineAdmissionRegistry?
    private let now: @Sendable () -> Date
    private var keys: CmxIrohGrantVerificationKeySet
    private var acceptor: CmxIrohGrantPeer
    private var pairingEnabled: Bool
    private var revokedBindingIDs: Set<String> = []

    public init(
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohGrantPeer,
        pairingEnabled: Bool,
        offlineSessions: CmxIrohOfflinePairingSessions,
        onlineRegistry: CmxIrohOnlineAdmissionRegistry? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keys = keys
        self.acceptor = acceptor
        self.pairingEnabled = pairingEnabled
        self.offlineSessions = offlineSessions
        self.onlineRegistry = onlineRegistry
        self.verifier = verifier
        self.now = now
    }

    /// Atomically replaces authenticated broker policy after a registry refresh.
    public func update(
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohGrantPeer,
        pairingEnabled: Bool
    ) async {
        self.keys = keys
        self.acceptor = acceptor
        self.pairingEnabled = pairingEnabled
        await offlineSessions.setPairingEnabled(pairingEnabled)
        await onlineRegistry?.update(keys: keys, acceptor: acceptor)
    }

    /// Applies local revoke before the backend round trip completes.
    public func revoke(bindingID: String) async {
        revokedBindingIDs.insert(bindingID)
        await offlineSessions.revoke(bindingID: bindingID)
        await onlineRegistry?.revoke(bindingID: bindingID)
    }

    public func authorize(
        credential: CmxIrohAdmissionCredential,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohAdmissionAuthorization {
        guard pairingEnabled,
              acceptor.platform == .mac,
              !revokedBindingIDs.contains(acceptor.bindingID) else {
            return .denied(code: 1)
        }
        do {
            switch credential.kind {
            case .pairGrant:
                guard let token = credential.pairGrantToken else {
                    return .denied(code: 1)
                }
                if let onlineRegistry {
                    switch await onlineRegistry.authorizePairGrant(
                        token,
                        authenticatedPeerID: authenticatedPeerID
                    ) {
                    case let .accepted(lease):
                        return .accepted(lease.peer, onlineLease: lease)
                    case .denied:
                        return .denied(code: 1)
                    }
                }
                let claims = try verifier.verifyPairGrant(
                    token,
                    keys: keys,
                    authenticatedInitiatorID: authenticatedPeerID,
                    acceptor: acceptor,
                    now: now()
                )
                guard !revokedBindingIDs.contains(claims.initiator.bindingID) else {
                    return .denied(code: 1)
                }
                return .accepted(
                    CmxIrohAdmittedPeer(peer: claims.initiator),
                    onlineLease: nil
                )
            case .offlinePairing:
                let pair = try await offlineSessions.verifyAndConsume(
                    credential: credential,
                    authenticatedPeerID: authenticatedPeerID,
                    now: now()
                )
                return .accepted(
                    CmxIrohAdmittedPeer(attestation: pair.initiator),
                    onlineLease: nil
                )
            }
        } catch {
            return .denied(code: 1)
        }
    }
}
