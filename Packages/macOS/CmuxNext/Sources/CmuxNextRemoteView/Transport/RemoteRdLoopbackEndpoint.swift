/// A development host on this Mac's loopback interface (remote-desktop.md
/// 11.0: phase-1 hosts listen only on loopback). The transport connects to a
/// literal 127.0.0.1, never a resolved name.
public nonisolated struct RemoteRdLoopbackEndpoint: Sendable, Hashable {
    public let port: UInt16

    /// Nil for a privileged port (the host refuses ports below 1024 too).
    public init?(port: UInt16) {
        guard port >= 1024 else { return nil }
        self.port = port
    }
}
