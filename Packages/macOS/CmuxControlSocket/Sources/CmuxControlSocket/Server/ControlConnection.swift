public import Darwin
public import Foundation

/// An accepted, configured control-socket client connection, delivered to the
/// host through ``SocketControlServer/connections``.
///
/// Ownership of the descriptor transfers to the consumer, which must
/// eventually `close(2)` it (the legacy `clientAccepted` contract).
public struct ControlConnection: Sendable {
    /// Stable identity for this accepted socket lifetime. Host command state
    /// that must be isolated per client (for example terminal viewport
    /// overrides) is keyed by this value and is discarded when the handler
    /// returns.
    public let id: UUID

    /// The accepted client socket descriptor.
    public let socket: Int32

    /// The peer process ID, captured via `LOCAL_PEERPID` in the accept loop
    /// before short-lived clients can disconnect; `nil` when the lookup
    /// failed.
    public let peerProcessID: pid_t?

    /// Access-policy generation captured when the server accepted this client.
    public let authorizationGeneration: UInt64

    /// Pollable signal for revocation of the captured authorization generation.
    public let authorizationRevocationSignal: SocketAuthorizationRevocationSignal

    /// Creates a connection value.
    /// - Parameters:
    ///   - socket: The accepted client socket descriptor.
    ///   - peerProcessID: The peer PID captured at accept time, if available.
    ///   - authorizationGeneration: Access-policy generation at accept time.
    ///   - authorizationRevocationSignal: Signal revoked with the generation.
    public init(
        id: UUID = UUID(),
        socket: Int32,
        peerProcessID: pid_t?,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal =
            SocketAuthorizationRevocationSignal()
    ) {
        self.id = id
        self.socket = socket
        self.peerProcessID = peerProcessID
        self.authorizationGeneration = authorizationGeneration
        self.authorizationRevocationSignal = authorizationRevocationSignal
    }
}
