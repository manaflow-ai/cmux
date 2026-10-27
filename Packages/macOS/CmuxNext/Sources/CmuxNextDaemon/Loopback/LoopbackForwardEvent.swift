import CmuxNextCompat
import Foundation

/// One `loopback-*` event line.
enum LoopbackForwardEvent: Sendable, Equatable {
    case data(stream: UInt64, bytes: Data)
    case credit(stream: UInt64, bytes: Int)
    case eof(stream: UInt64)
    case closed(stream: UInt64, error: String?)

    var stream: UInt64 {
        switch self {
        case .data(let stream, _), .credit(let stream, _), .eof(let stream), .closed(let stream, _): stream
        }
    }

    private struct Raw: Decodable {
        var stream: UInt64
        var data: String?
        var bytes: Int?
        var error: String?
    }

    /// nil for other events and malformed lines.
    static func decode(name: String, line: Data, decoder: WireDecoder = WireCoding.decoder()) -> LoopbackForwardEvent? {
        guard name.hasPrefix("loopback-"), let raw = try? decoder.decode(Raw.self, from: line) else { return nil }
        switch name {
        case "loopback-data":
            guard let text = raw.data, let bytes = Data(base64Encoded: text) else { return nil }
            return .data(stream: raw.stream, bytes: bytes)
        case "loopback-credit":
            guard let bytes = raw.bytes, bytes > 0 else { return nil }
            return .credit(stream: raw.stream, bytes: bytes)
        case "loopback-eof":
            return .eof(stream: raw.stream)
        case "loopback-closed":
            return .closed(stream: raw.stream, error: raw.error)
        default:
            return nil
        }
    }
}

/// Encodes the id-less, reply-less stream lines (no newline).
enum LoopbackForwardLine {
    static func data(stream: UInt64, bytes: Data) -> Data {
        line(["cmd": "loopback-data", "stream": stream, "data": bytes.base64EncodedString()])
    }

    static func credit(stream: UInt64, bytes: Int) -> Data {
        line(["cmd": "loopback-credit", "stream": stream, "bytes": bytes])
    }

    static func shutdown(stream: UInt64) -> Data {
        line(["cmd": "loopback-shutdown", "stream": stream])
    }

    static func close(stream: UInt64) -> Data {
        line(["cmd": "loopback-close", "stream": stream])
    }

    private static func line(_ object: [String: any Sendable]) -> Data {
        // Only strings and integers: serialization cannot fail.
        (try? CheckedJSON.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
