import Foundation

/// The viewer's first message. Phase 1: the host trusts these claims only
/// on loopback or a single-tenant overlay (remote-desktop.md 11.0).
public nonisolated struct RemoteRdHello: Sendable, Equatable, Codable {
    public var user: String
    public var install: String
    public var principalClass: String
    public var interactive: Bool
    /// The viewer's UDP port for media, or nil for the stream carrier.
    public var udpPort: UInt16?
    public var maxDatagram: Int
    /// The per-launch session token, 64 hex characters.
    public var token: String?
    /// The service this session is for (rd change C1).
    public var service: String
    /// Optional rd features this viewer supports (rd change C1).
    public var caps: [String]

    public init(
        user: String, install: String, principalClass: String = "user", interactive: Bool = true,
        udpPort: UInt16? = nil, maxDatagram: Int = 1152, token: String?, service: String = "desktop",
        caps: [String] = []
    ) {
        self.user = user
        self.install = install
        self.principalClass = principalClass
        self.interactive = interactive
        self.udpPort = udpPort
        self.maxDatagram = maxDatagram
        self.token = token
        self.service = service
        self.caps = caps
    }

    enum CodingKeys: String, CodingKey {
        case user, install, interactive, token, service, caps
        case principalClass = "class"
        case udpPort = "udp_port"
        case maxDatagram = "max_datagram"
    }
}

/// The host's answer to a hello and start.
public nonisolated struct RemoteRdWelcome: Sendable, Equatable, Codable {
    public var encoder: String
    public var width: UInt32
    public var height: UInt32
    public var maxDatagram: Int
    public var carrier: String
    /// The service the host routed the session to; nil from a host older than C1.
    public var service: String?
    /// The offered caps the host also supports.
    public var caps: [String]?

    public init(
        encoder: String, width: UInt32, height: UInt32, maxDatagram: Int, carrier: String,
        service: String? = nil, caps: [String]? = nil
    ) {
        self.encoder = encoder
        self.width = width
        self.height = height
        self.maxDatagram = maxDatagram
        self.carrier = carrier
        self.service = service
        self.caps = caps
    }

    enum CodingKeys: String, CodingKey {
        case encoder, width, height, carrier, service, caps
        case maxDatagram = "max_datagram"
    }
}

/// The host's periodic counters.
public nonisolated struct RemoteRdHostStats: Sendable, Equatable, Codable {
    public var kbps: UInt32
    public var frames: UInt64
    public var keyframes: UInt64
    public var cpuPercent: Double
    public var encodeMsP50: Double
    public var lossPercent: Double

    enum CodingKeys: String, CodingKey {
        case kbps, frames, keyframes
        case cpuPercent = "cpu_pct"
        case encodeMsP50 = "encode_ms_p50"
        case lossPercent = "loss_pct"
    }
}
