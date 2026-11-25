public import CmuxNextDaemon

extension DaemonIdentity {
    /// Why a link socket was refused after the handshake.
    static let localDaemonDetail = "the link socket is this Mac's own daemon"
    static let noLocalIdentityDetail = "this Mac's daemon identity is unknown"

    /// The post-handshake check of a link socket whose daemon is this identity
    /// (the path check runs before the connect, `CloudLinkSocketPolicy`): it
    /// must not be this Mac's own daemon (`local`), the same boot
    /// (`generation`) or the same session (`sessionID`: the registry id,
    /// lowercased, empty = none). Without a local identity there is nothing to
    /// compare, so the link is refused (fail closed).
    public func checkNotLocal(local: DaemonIdentity?) throws {
        guard let local else { throw CloudLinkError.unsafeSocket(Self.noLocalIdentityDetail) }
        let sameSession = sessionID != nil && sessionID == local.sessionID
        if generation == local.generation || sameSession {
            throw CloudLinkError.unsafeSocket(Self.localDaemonDetail)
        }
    }
}
