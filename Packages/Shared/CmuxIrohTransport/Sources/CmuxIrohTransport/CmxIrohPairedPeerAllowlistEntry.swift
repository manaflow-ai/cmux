public import Foundation

/// One phone endpoint whose pairing this Mac has already verified once.
///
/// The entry pins the complete initiator and acceptor tuples the verified pair
/// grant carried, so allowlist admission preserves exactly the account-scoped
/// binding authority the grant used to prove in-band. `expiresAt` is the
/// signed expiry of the last verified grant: allowlist authority never
/// outlives the credential that established it.
public struct CmxIrohPairedPeerAllowlistEntry: Equatable, Sendable {
    /// The exact phone tuple the verified grant named as initiator.
    public let initiator: CmxIrohGrantPeer

    /// The exact Mac tuple the verified grant named as acceptor.
    public let acceptor: CmxIrohGrantPeer

    /// The signed expiry of the grant that established this entry.
    public let expiresAt: Date

    /// When the pairing was recorded; oldest entries are pruned first.
    public let recordedAt: Date

    /// Creates one verified-pairing entry.
    ///
    /// - Parameters:
    ///   - initiator: The grant's exact phone tuple.
    ///   - acceptor: The grant's exact Mac tuple.
    ///   - expiresAt: The grant's signed expiry.
    ///   - recordedAt: The verification time used for pruning order.
    public init(
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        expiresAt: Date,
        recordedAt: Date
    ) {
        self.initiator = initiator
        self.acceptor = acceptor
        self.expiresAt = expiresAt
        self.recordedAt = recordedAt
    }
}
