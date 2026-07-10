public import Foundation

/// Online revocation state for one locally authenticated pair grant.
public enum CmxIrohOnlineAdmissionAuthorization: Equatable, Sendable {
    /// The exact peer may use the transport until the lease is invalidated.
    case accepted(CmxIrohOnlineAdmissionLease)

    /// Local authentication or current broker policy denied the peer.
    case denied
}

/// A locally authenticated pair grant whose broker binding remains subject to refresh.
public struct CmxIrohOnlineAdmissionLease: Equatable, Sendable {
    public let peer: CmxIrohAdmittedPeer
    public let expiresAt: Date

    let grantID: String
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let onlineValidatedAt: Date?

    init(claims: CmxIrohPairGrantClaims, onlineValidatedAt: Date?) {
        peer = CmxIrohAdmittedPeer(peer: claims.initiator)
        expiresAt = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        grantID = claims.grantID
        initiator = claims.initiator
        acceptor = claims.acceptor
        self.onlineValidatedAt = onlineValidatedAt
    }
}
