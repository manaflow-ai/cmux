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

    /// Creates a connection value.
    /// - Parameters:
    ///   - socket: The accepted client socket descriptor.
    ///   - peerProcessID: The peer PID captured at accept time, if available.
    public init(socket: Int32, peerProcessID: pid_t?) {
        self.socket = socket
        self.peerProcessID = peerProcessID
    }
}
