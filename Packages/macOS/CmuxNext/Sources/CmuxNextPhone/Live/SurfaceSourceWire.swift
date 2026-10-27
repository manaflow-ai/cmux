public import Foundation

/// `sf/1`, the loopback protocol between cmux-mobile-host and a simulator
/// surface source (cmux-mobile-host `surface.rs`): `u8 kind | u32 BE length |
/// payload`. Kind 1 is a JSON object either way; kind 2 is an access unit from
/// the source: `u8 flags (bit 0: IDR) | u64 BE capture time (µs, CLOCK_UPTIME_RAW) | Annex B`.
public struct SurfaceSourceWire: Sendable, Equatable {
    /// One frame read off the wire.
    public enum Frame: Sendable, Equatable {
        case json([String: SurfaceSourceValue])
        case accessUnit(idr: Bool, captureMicros: UInt64, annexB: Data)
    }

    /// The largest frame hostd sends a source (its lines are small).
    public static let maximumIncoming = 1 << 20

    private var buffer = Data()

    public init() {}

    /// A JSON line, framed.
    public static func json(_ object: [String: Any]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return frame(kind: 1, payload)
    }

    /// An access unit, framed.
    public static func accessUnit(idr: Bool, captureMicros: UInt64, annexB: Data) -> Data {
        var payload = Data(capacity: 9 + annexB.count)
        payload.append(idr ? 1 : 0)
        payload.appendBigEndian(captureMicros)
        payload.append(annexB)
        return frame(kind: 2, payload)
    }

    private static func frame(kind: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(kind)
        // decode-trap-allow: this side frames only its own JSON lines and encoded access units, far below 4 GiB.
        out.appendBigEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next whole frame; nil until one is complete. The header and payload are read as
    /// prefixes of the buffer, never by position, so no peer bytes can index past it.
    public mutating func next() throws(SurfaceSourceWireError) -> Frame? {
        guard buffer.count >= 5, let kind = buffer.first else { return nil }
        // A u32 length always fits a 64-bit Int; it is bounded below before any use.
        let length = Int(truncatingIfNeeded: Self.bigEndian(buffer.dropFirst().prefix(4)))
        guard length <= Self.maximumIncoming else { throw .tooLarge }
        guard buffer.count >= 5 + length else { return nil }
        let payload = Data(buffer.dropFirst(5).prefix(length))
        buffer = Data(buffer.dropFirst(5 + length))
        switch kind {
        case 1:
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw .malformed }
            return .json(object.compactMapValues(SurfaceSourceValue.init))
        case 2:
            guard payload.count >= 9, let flags = payload.first else { throw .malformed }
            let stamp = Self.bigEndian(payload.dropFirst().prefix(8))
            return .accessUnit(idr: flags & 1 == 1, captureMicros: stamp, annexB: Data(payload.dropFirst(9)))
        default:
            throw .malformed
        }
    }

    /// Big-endian bytes as one integer (at most 8 bytes: each widens exactly into the `UInt64`).
    private static func bigEndian(_ bytes: Data) -> UInt64 {
        bytes.reduce(UInt64(0)) { $0 << 8 | UInt64(truncatingIfNeeded: $1) }
    }
}

public enum SurfaceSourceWireError: Error, Sendable, Equatable {
    case tooLarge
    case malformed
}

/// A JSON value of an `sf/1` line (strings, numbers and booleans are all the protocol uses).
public enum SurfaceSourceValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init?(_ any: Any) {
        if let number = any as? NSNumber {
            // JSONSerialization gives booleans as NSNumber of the CFBoolean type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        } else if let text = any as? String {
            self = .string(text)
        } else {
            return nil
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}
