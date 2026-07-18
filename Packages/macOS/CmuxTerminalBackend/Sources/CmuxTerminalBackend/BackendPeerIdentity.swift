/// Kernel-reported identity of the process at the other end of a backend socket.
public struct BackendPeerIdentity: Equatable, Sendable {
    /// The process identifier attached to the connected Unix socket by macOS.
    public let processID: UInt32

    /// The effective user identifier attached to the connected Unix socket by macOS.
    public let userID: UInt32

    /// The non-reusable process identity attached to the same socket.
    public let auditToken: BackendAuditToken

    /// Creates a kernel peer identity.
    ///
    /// - Parameters:
    ///   - processID: The operating-system process identifier.
    ///   - userID: The effective operating-system user identifier.
    ///   - auditToken: The audit token read from this exact connection.
    public init(
        processID: UInt32,
        userID: UInt32,
        auditToken: BackendAuditToken
    ) {
        self.processID = processID
        self.userID = userID
        self.auditToken = auditToken
    }
}
