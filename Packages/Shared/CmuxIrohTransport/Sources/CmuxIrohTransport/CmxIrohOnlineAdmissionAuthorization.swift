public import Foundation

/// Online revocation state for locally authenticated pair authority.
public enum CmxIrohOnlineAdmissionAuthorization: Equatable, Sendable {
    /// The exact peer may use the transport until the lease is invalidated.
    case accepted(CmxIrohOnlineAdmissionLease)

    /// Local authentication or current broker policy denied the peer.
    case denied
}

/// Locally authenticated authority whose broker bindings remain subject to refresh.
public struct CmxIrohOnlineAdmissionLease: Equatable, Sendable {
    enum Authority: Equatable, Sendable {
        case pairGrant(
            grantID: String,
            initiator: CmxIrohGrantPeer,
            acceptor: CmxIrohGrantPeer
        )
        case offlinePairing(
            initiator: CmxIrohEndpointExpectation,
            acceptor: CmxIrohEndpointExpectation
        )
        /// A previously grant-verified pairing admitted from the Mac's local
        /// allowlist with no in-band credential. Broker bindings are validated
        /// exactly as for a live pair grant.
        case pairedEndpoint(
            initiator: CmxIrohGrantPeer,
            acceptor: CmxIrohGrantPeer
        )

        var initiatorBindingID: String {
            switch self {
            case let .pairGrant(_, initiator, _): initiator.bindingID
            case let .offlinePairing(initiator, _): initiator.bindingID
            case let .pairedEndpoint(initiator, _): initiator.bindingID
            }
        }

        var acceptorBindingID: String {
            switch self {
            case let .pairGrant(_, _, acceptor): acceptor.bindingID
            case let .offlinePairing(_, acceptor): acceptor.bindingID
            case let .pairedEndpoint(_, acceptor): acceptor.bindingID
            }
        }
    }

    public let peer: CmxIrohAdmittedPeer
    public let expiresAt: Date

    let authority: Authority
    let onlineValidatedAt: Date?

    private init(
        peer: CmxIrohAdmittedPeer,
        expiresAt: Date,
        authority: Authority,
        onlineValidatedAt: Date?
    ) {
        self.peer = peer
        self.expiresAt = expiresAt
        self.authority = authority
        self.onlineValidatedAt = onlineValidatedAt
    }

    init(claims: CmxIrohPairGrantClaims, onlineValidatedAt: Date?) {
        peer = CmxIrohAdmittedPeer(peer: claims.initiator)
        expiresAt = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        authority = .pairGrant(
            grantID: claims.grantID,
            initiator: claims.initiator,
            acceptor: claims.acceptor
        )
        self.onlineValidatedAt = onlineValidatedAt
    }

    init(pair: CmxIrohVerifiedOfflinePair, onlineValidatedAt: Date?) {
        peer = CmxIrohAdmittedPeer(attestation: pair.initiator)
        expiresAt = Date(
            timeIntervalSince1970: TimeInterval(
                min(pair.initiator.expiresAt, pair.acceptor.expiresAt)
            )
        )
        authority = .offlinePairing(
            initiator: CmxIrohEndpointExpectation(
                bindingID: pair.initiator.bindingID,
                deviceID: pair.initiator.deviceID,
                endpointID: pair.initiator.endpointID,
                identityGeneration: pair.initiator.identityGeneration,
                platform: pair.initiator.platform
            ),
            acceptor: CmxIrohEndpointExpectation(
                bindingID: pair.acceptor.bindingID,
                deviceID: pair.acceptor.deviceID,
                endpointID: pair.acceptor.endpointID,
                identityGeneration: pair.acceptor.identityGeneration,
                platform: pair.acceptor.platform
            )
        )
        self.onlineValidatedAt = onlineValidatedAt
    }

    init(
        pairedInitiator initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        expiresAt: Date,
        onlineValidatedAt: Date?
    ) {
        peer = CmxIrohAdmittedPeer(peer: initiator)
        self.expiresAt = expiresAt
        authority = .pairedEndpoint(initiator: initiator, acceptor: acceptor)
        self.onlineValidatedAt = onlineValidatedAt
    }

    func validatedOnline(at date: Date) -> Self {
        Self(
            peer: peer,
            expiresAt: expiresAt,
            authority: authority,
            onlineValidatedAt: date
        )
    }
}
