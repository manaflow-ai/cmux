/// A JSON value kept whole: a catalog `json` field, an undiscriminated union's value, the raw
/// object of an unknown union tag and the details of an unknown error code. The same shape as
/// CmuxNextDaemon's `JSONValue`, which this leaf target cannot import.
public enum ResourceJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ResourceJSON])
    case object([String: ResourceJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ResourceJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ResourceJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A coding key spelled at run time: the tag of a generated tagged union, and the container of
/// a generated empty object.
public struct ResourceCodingKey: CodingKey, Sendable {
    public var stringValue: String

    public var intValue: Int? { nil }

    public init(_ name: String) {
        stringValue = name
    }

    public init?(stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(intValue: Int) {
        return nil
    }

    /// The string at key `discriminator` of the object `decoder` holds.
    public static func discriminator(_ discriminator: String, in decoder: any Decoder) throws -> String {
        let container = try decoder.container(keyedBy: ResourceCodingKey.self)
        return try container.decode(String.self, forKey: ResourceCodingKey(discriminator))
    }

    /// A tagged union's refusal of tag `tag`: the union keeps no unknown variant, so an
    /// undeclared tag is a decoding error rather than a guess.
    public static func unrecognized(_ tag: String, discriminator: String, in decoder: any Decoder) -> DecodingError {
        var path = decoder.codingPath
        path.append(ResourceCodingKey(discriminator))
        return .dataCorrupted(DecodingError.Context(codingPath: path, debugDescription: "unknown \(discriminator) \(tag)"))
    }
}
