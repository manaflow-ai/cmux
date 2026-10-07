/// Limits of the `tcp.forward` service (c14-web.md section 3.2).
public struct MobileTunnelConfiguration: Hashable, Sendable {
    /// Ports never forwarded even when advertised (the daemon's control port, the app's own listeners).
    public var deniedPorts: Set<UInt16>
    public var maxStreamsPerDevice: Int
    public var maxStreamsTotal: Int
    public var connectTimeout: Duration
    /// Largest record the host sends; the link chunks nothing for us.
    public var chunkBytes: Int

    public init(deniedPorts: Set<UInt16> = [], maxStreamsPerDevice: Int = 32, maxStreamsTotal: Int = 128,
                connectTimeout: Duration = .seconds(3), chunkBytes: Int = 64 * 1024) {
        self.deniedPorts = deniedPorts
        self.maxStreamsPerDevice = maxStreamsPerDevice
        self.maxStreamsTotal = maxStreamsTotal
        self.connectTimeout = connectTimeout
        self.chunkBytes = chunkBytes
    }
}
