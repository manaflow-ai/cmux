/// Where and how a host listens for direct connections.
public struct DirectListenConfiguration: Sendable, Hashable {
    /// `0` picks a free port (tests); hosts use `DirectEndpoint.defaultPort`.
    public var port: UInt16
    /// Bind to one local address (`127.0.0.1` in tests); nil listens on all.
    public var localAddress: String?
    /// Advertise `_cmux._tcp` with this service name; nil disables Bonjour.
    public var bonjourName: String?
    /// How long an incoming connection may take to finish the handshake.
    public var handshakeTimeout: Duration

    public init(
        port: UInt16 = DirectEndpoint.defaultPort,
        localAddress: String? = nil,
        bonjourName: String? = nil,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.port = port
        self.localAddress = localAddress
        self.bonjourName = bonjourName
        self.handshakeTimeout = handshakeTimeout
    }
}
