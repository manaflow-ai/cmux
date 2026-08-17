public import Darwin

/// An accepted, configured control-socket client connection, delivered to the
/// host through ``SocketControlServer/connections``.
///
/// Ownership of the descriptor transfers to the consumer, which must
/// eventually `close(2)` it (the legacy `clientAccepted` contract).
public struct ControlConnection: Sendable {
    /// The accepted client socket descriptor.
    public let socket: Int32

    /// The peer process ID, captured via `LOCAL_PEERPID` in the accept loop
    /// before short-lived clients can disconnect; `nil` when the lookup
    /// failed.
    public let peerProcessID: pid_t?

    /// The peer audit token copied with `LOCAL_PEERTOKEN` in the accept loop.
    /// It is `nil` when the kernel lookup failed.
    public let peerAuditToken: SocketPeerAuditToken?

    /// Process start time captured for ``peerProcessID`` at accept.
    public let peerProcessStartTime: SocketPeerProcessStartTime?

    /// Access-policy generation captured when the server accepted this client.
    public let authorizationGeneration: UInt64

    /// Pollable signal for revocation of the captured authorization generation.
    public let authorizationRevocationSignal: SocketAuthorizationRevocationSignal

    /// Creates a connection value.
    /// - Parameters:
    ///   - socket: The accepted client socket descriptor.
    ///   - peerProcessID: The peer PID captured at accept time, if available.
    ///   - peerAuditToken: The immutable peer audit token captured at accept.
    ///   - peerProcessStartTime: The peer process start time captured at accept.
    ///   - authorizationGeneration: Access-policy generation at accept time.
    ///   - authorizationRevocationSignal: Signal revoked with the generation.
    public init(
        socket: Int32,
        peerProcessID: pid_t?,
        peerAuditToken: SocketPeerAuditToken? = nil,
        peerProcessStartTime: SocketPeerProcessStartTime? = nil,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal =
            SocketAuthorizationRevocationSignal()
    ) {
        self.socket = socket
        self.peerProcessID = peerProcessID
        self.peerAuditToken = peerAuditToken
        self.peerProcessStartTime = peerProcessStartTime
        self.authorizationGeneration = authorizationGeneration
        self.authorizationRevocationSignal = authorizationRevocationSignal
    }
}
