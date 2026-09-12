import Foundation

/// The credential handoff a local container needs to reach a cmux control socket.
///
/// The capability is audience-bound to the issuing cmux app and is accepted only
/// for same-UID peers. The socket path is returned alongside it so callers do not
/// accidentally bridge a stale development socket.
public struct SocketClientCapabilityLease: Codable, Equatable, Sendable {
    /// The live Unix socket path to bridge or mount into the container.
    public let socketPath: String

    /// The opaque capability to present in a `_cmux_capability_v1` envelope.
    public let capability: String

    /// The wire envelope understood by cmux control sockets.
    public let protocolName: String

    public init(socketPath: String, capability: String) {
        self.socketPath = socketPath
        self.capability = capability
        protocolName = "_cmux_capability_v1"
    }
}
