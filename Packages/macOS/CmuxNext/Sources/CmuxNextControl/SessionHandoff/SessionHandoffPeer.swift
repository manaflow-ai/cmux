public import Darwin

/// What the kernel recorded for the other end of a connected Unix socket: its user and its audit token.
///
/// The audit token names one process instance (it carries the pid version), so a code check made with
/// it cannot be fooled by a pid that was reused, or a process that exec'd, after the connection was made.
public struct SessionHandoffPeer: Sendable {
    /// The peer's effective user id (`LOCAL_PEERCRED`).
    public var uid: uid_t
    /// The peer's audit token (`LOCAL_PEERTOKEN`).
    public var auditToken: audit_token_t

    /// - Parameters:
    ///   - uid: The peer's user id.
    ///   - auditToken: The peer's audit token.
    public init(uid: uid_t, auditToken: audit_token_t) {
        self.uid = uid
        self.auditToken = auditToken
    }

    /// The peer of a connected `AF_UNIX` socket, or nil when the kernel answers neither question.
    /// On a server's accepted socket that is the client; on a client's connected socket, the process
    /// that listens.
    public init?(connection descriptor: Int32) {
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0,
              tokenSize == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        self.init(uid: credentials.cr_uid, auditToken: token)
    }
}
