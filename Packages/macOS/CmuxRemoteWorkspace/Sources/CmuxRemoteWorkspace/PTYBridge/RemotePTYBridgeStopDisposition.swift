/// Describes whether a stopped loopback PTY bridge ever accepted a local client.
public enum RemotePTYBridgeStopDisposition: Sendable, Equatable {
    /// The endpoint stopped before any local client connected.
    case unused
    /// A local client connected, so its logical generation may need to survive a reconnect gap.
    case acceptedClient
}
