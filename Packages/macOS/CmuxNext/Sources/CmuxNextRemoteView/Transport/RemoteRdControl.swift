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
    /// A message of the session's service (an rb/1 body), passed through
    /// untouched (rd change B3.2); rd never interprets `body`.
    case service(service: String, body: RemoteRdJSON)
    /// Bulk flow control (rd change C5): the receiver of `transfer` allows
    /// bytes before `offset`.
    case bulkCredit(transfer: UInt64, offset: UInt64)
    /// Opens a stream (sent only when welcome lists `stream.open`).
    case streamOpen(RemoteRdStreamOpen)
    /// The peer accepted `stream_open` for `stream`.
    case streamOpened(stream: UInt16)
    /// The peer refused `stream_open` for `stream` (`caps`, `kind`, `codec`,
    /// `unsupported`, `in_use`, `too_many`, `view_only`).
    case streamRefused(stream: UInt16, reason: String)
    /// Closes an opened stream; no answer.
    case streamClose(stream: UInt16)
    /// A message type this viewer does not know (a newer host); ignored.
    case unknown(String)
}

nonisolated extension RemoteRdControl: Codable {
    private enum TagKey: String, CodingKey { case t }
    private enum Fields: String, CodingKey { case key, mode, session, reason, service, body, transfer, offset, stream }

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
        case "service":
            self = .service(
                service: try fields.decode(String.self, forKey: .service),
                body: try fields.decode(RemoteRdJSON.self, forKey: .body)
            )
        case "bulk_credit":
            self = .bulkCredit(
                transfer: try fields.decode(UInt64.self, forKey: .transfer),
                offset: try fields.decode(UInt64.self, forKey: .offset)
            )
        case "stream_open": self = .streamOpen(try RemoteRdStreamOpen(from: decoder))
        case "stream_opened": self = .streamOpened(stream: try fields.decode(UInt16.self, forKey: .stream))
        case "stream_refused":
            self = .streamRefused(
                stream: try fields.decode(UInt16.self, forKey: .stream),
                reason: try fields.decode(String.self, forKey: .reason)
            )
        case "stream_close": self = .streamClose(stream: try fields.decode(UInt16.self, forKey: .stream))
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
        case let .service(service, body):
            try tag.encode("service", forKey: .t)
            try fields.encode(service, forKey: .service)
            try fields.encode(body, forKey: .body)
        case let .bulkCredit(transfer, offset):
            try tag.encode("bulk_credit", forKey: .t)
            try fields.encode(transfer, forKey: .transfer)
            try fields.encode(offset, forKey: .offset)
        case let .streamOpen(open):
            try tag.encode("stream_open", forKey: .t)
            try open.encode(to: encoder)
        case let .streamOpened(stream):
            try tag.encode("stream_opened", forKey: .t)
            try fields.encode(stream, forKey: .stream)
        case let .streamRefused(stream, reason):
            try tag.encode("stream_refused", forKey: .t)
            try fields.encode(stream, forKey: .stream)
            try fields.encode(reason, forKey: .reason)
        case let .streamClose(stream):
            try tag.encode("stream_close", forKey: .t)
            try fields.encode(stream, forKey: .stream)
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
