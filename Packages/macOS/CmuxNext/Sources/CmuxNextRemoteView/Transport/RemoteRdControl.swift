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
