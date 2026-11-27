import CoreGraphics
import Foundation

/// The host's screen stream rules, asked of Rust (cmux-tui/crates/cmux-rd-screen, with their
/// tests; ops `screen_*`): viewer demand, the viewer's caps, the cursor shape's id and delivery,
/// and follow mode's focus producer. This package links no Rust library itself (the app links its
/// one, CCmuxAppFFI; cmux Remote opens libcmux_rd_screen.dylib), so the process that runs a host
/// hands its channel to each host and capture backend it makes (``ScreenStreamHost``'s and
/// ``ScreenCaptureBackend``'s `rules:`). Without one (cmux-vnc-host, tests) a host streams the full
/// display with the cursor in the picture and sends no focus signals.
public struct ScreenRules: Sendable {
    /// One JSON call: the operation and its request, the answer (nil: no answer).
    public typealias Ask = @Sendable (_ operation: String, _ request: Data) -> Data?

    private let channel: Ask?

    /// The rules answered by `ask`; none without it.
    public init(_ ask: Ask? = nil) {
        channel = ask
    }

    /// Whether there is a channel.
    var installed: Bool { channel != nil }

    /// One call, decoded; nil without a channel or for an answer that does not decode.
    func ask<Answer: Decodable>(_ operation: String, _ request: some Encodable, as _: Answer.Type = Answer.self) -> Answer? {
        guard let channel, let data = try? JSONEncoder().encode(request),
              let answer = channel(operation, data) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: answer)
    }
}

/// State Rust keeps between calls (the demand, the cursor delivery, the focus producer), held
/// here as the JSON it came back as and sent back unread.
enum ScreenJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ScreenJSON])
    case object([String: ScreenJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null } else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ScreenJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ScreenJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    subscript(key: String) -> ScreenJSON? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var int: Int? {
        if case let .integer(value) = self { return Int(exactly: value) }
        return nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

/// cmux-rd-screen's geometry as it reads it (`{x,y,w,h}`, `{w,h}`, `{x,y}`).
struct ScreenRect: Codable, Sendable, Equatable {
    var x: Double, y: Double, w: Double, h: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        w = Double(rect.width)
        h = Double(rect.height)
    }
}

struct ScreenSize: Codable, Sendable, Equatable {
    var w: Double, h: Double

    init(_ size: CGSize) {
        w = Double(size.width)
        h = Double(size.height)
    }

    var cgSize: CGSize { CGSize(width: w, height: h) }
}

struct ScreenPoint: Codable, Sendable, Equatable {
    var x: Double, y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}
