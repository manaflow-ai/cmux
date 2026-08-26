import Foundation

/// Minimal JSON value for frame payloads: keeps the wire schemaless while the
/// typed accessors keep call sites honest.
public indirect enum PtxJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PtxJSON])
    case object([String: PtxJSON])

    /// Binary payloads travel as base64 strings.
    public static func data(_ data: Data) -> PtxJSON {
        .string(data.base64EncodedString())
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(exactly: value.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        guard case .string(let value) = self else { return nil }
        return Data(base64Encoded: value)
    }

    public var arrayValue: [PtxJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: PtxJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PtxJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PtxJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unsupported JSON value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
