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
        withUnsafeBytes(of: captureMicros.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(annexB)
        return frame(kind: 2, payload)
    }

    private static func frame(kind: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(kind)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next whole frame; nil until one is complete.
    public mutating func next() throws(SurfaceSourceWireError) -> Frame? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let kind = buffer[start]
        let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maximumIncoming else { throw .tooLarge }
        guard buffer.count >= 5 + length else { return nil }
        let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
        buffer.removeSubrange(start..<(start + 5 + length))
        switch kind {
        case 1:
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw .malformed }
            return .json(object.compactMapValues(SurfaceSourceValue.init))
        case 2:
            guard payload.count >= 9 else { throw .malformed }
            let base = payload.startIndex
            let stamp = payload[(base + 1)..<(base + 9)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return .accessUnit(idr: payload[base] & 1 == 1, captureMicros: stamp, annexB: Data(payload[(base + 9)...]))
        default:
            throw .malformed
        }
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
