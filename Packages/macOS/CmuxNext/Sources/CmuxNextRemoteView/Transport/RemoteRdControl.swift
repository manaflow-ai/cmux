public import Foundation

/// The `cmux.rd/1` control messages (JSON on the stream carrier's type-1
/// frames), field for field the host's `Control` enum in
/// cmux-tui/crates/cmux-rd-host/src/wire.rs (`#[serde(tag = "t")]`, snake
/// case). A copy until rd change C7 moves the typed control into
/// cmux-rd-proto; `RemoteRdControlTests` pins the JSON both sides speak.
public nonisolated enum RemoteRdControl: Sendable, Equatable {
    case hello(RemoteRdHello)
    case start(key: String, mode: String)
    case stop
    case welcome(RemoteRdWelcome)
    case started(session: UInt64)
    case refused(reason: String)
    case ended(reason: String)
    case stats(RemoteRdHostStats)
    /// A message type this viewer does not know (a newer host); ignored.
    case unknown(String)
}

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

nonisolated extension RemoteRdControl: Codable {
    private enum TagKey: String, CodingKey { case t }
    private enum Fields: String, CodingKey { case key, mode, session, reason }

    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: TagKey.self).decode(String.self, forKey: .t)
        let fields = try decoder.container(keyedBy: Fields.self)
        switch tag {
        case "hello": self = .hello(try RemoteRdHello(from: decoder))
        case "start":
            self = .start(key: try fields.decode(String.self, forKey: .key), mode: try fields.decode(String.self, forKey: .mode))
        case "stop": self = .stop
        case "welcome": self = .welcome(try RemoteRdWelcome(from: decoder))
        case "started": self = .started(session: try fields.decode(UInt64.self, forKey: .session))
        case "refused": self = .refused(reason: try fields.decode(String.self, forKey: .reason))
        case "ended": self = .ended(reason: try fields.decode(String.self, forKey: .reason))
        case "stats": self = .stats(try RemoteRdHostStats(from: decoder))
        default: self = .unknown(tag)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var tag = encoder.container(keyedBy: TagKey.self)
        var fields = encoder.container(keyedBy: Fields.self)
        switch self {
        case let .hello(hello):
            try tag.encode("hello", forKey: .t)
            try hello.encode(to: encoder)
        case let .start(key, mode):
            try tag.encode("start", forKey: .t)
            try fields.encode(key, forKey: .key)
            try fields.encode(mode, forKey: .mode)
        case .stop:
            try tag.encode("stop", forKey: .t)
        case let .welcome(welcome):
            try tag.encode("welcome", forKey: .t)
            try welcome.encode(to: encoder)
        case let .started(session):
            try tag.encode("started", forKey: .t)
            try fields.encode(session, forKey: .session)
        case let .refused(reason):
            try tag.encode("refused", forKey: .t)
            try fields.encode(reason, forKey: .reason)
        case let .ended(reason):
            try tag.encode("ended", forKey: .t)
            try fields.encode(reason, forKey: .reason)
        case let .stats(stats):
            try tag.encode("stats", forKey: .t)
            try stats.encode(to: encoder)
        case let .unknown(name):
            try tag.encode(name, forKey: .t)
        }
    }

    /// The JSON payload of a type-1 stream frame.
    public func json() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Parses a type-1 stream frame payload.
    public static func parse(_ json: Data) throws -> RemoteRdControl {
        try JSONDecoder().decode(RemoteRdControl.self, from: json)
    }
}
