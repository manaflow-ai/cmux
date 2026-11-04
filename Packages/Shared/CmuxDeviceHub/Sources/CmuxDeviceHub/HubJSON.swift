import CryptoKit
public import Foundation

/// A JSON value kept as the hub sent it, so a Computer Use request's digest can
/// be recomputed over every field, the ones this build does not know included
/// (docs/device-hub/PROTOCOL.md, "Computer Use approvals").
public enum HubJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    /// A JSON number without a fraction or exponent.
    case integer(Int64)
    /// Any other number: never canonical (the protocol allows integers only).
    case number(Double)
    case string(String)
    case array([HubJSON])
    case object([String: HubJSON])

    /// Canonical JSON refuses a number that is not an integer.
    public enum CanonicalError: Error, Equatable, Sendable {
        case notAnInteger
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HubJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: HubJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
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

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var objectValue: [String: HubJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// The canonical JSON text (PROTOCOL.md, Computer Use approvals): object keys
    /// sorted by code point, no whitespace, integers only, strings escaped only
    /// for `"`, `\`, `\b \f \n \r \t` and other U+0000-U+001F as `\u00xx`
    /// (lowercase hex). Everything else, `/` and non-ASCII included, is itself.
    /// Written by hand: JSONEncoder escapes `/` and orders keys its own way.
    public func canonical() throws -> String {
        var out = ""
        try write(into: &out)
        return out
    }

    /// The lowercase hex SHA-256 of the canonical JSON's UTF-8 bytes.
    public func canonicalSHA256() throws -> String {
        try Self.sha256Hex(Data(canonical().utf8))
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func write(into out: inout String) throws {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .integer(value): out += String(value)
        case .number: throw CanonicalError.notAnInteger
        case let .string(value): Self.writeString(value, into: &out)
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                try value.write(into: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            let keys = fields.keys.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                try fields[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{00}" ... "\u{1F}": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
