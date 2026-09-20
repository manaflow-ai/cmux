import Foundation

/// Bounded JSON value used by the cmux compatibility protocol.
public enum MobileRemoteCmuxJSONValue: Codable, Equatable, Sendable {
    /// JSON null.
    case null
    /// JSON boolean.
    case boolean(Bool)
    /// JSON number represented without lossy floating-point conversion.
    case number(String)
    /// JSON string.
    case string(String)
    /// JSON array.
    case array([MobileRemoteCmuxJSONValue])
    /// JSON object.
    case object([String: MobileRemoteCmuxJSONValue])

    /// Returns a string when this value is a JSON string.
    public var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    /// Returns a boolean when this value is a JSON boolean.
    public var booleanValue: Bool? { if case let .boolean(value) = self { value } else { nil } }
    /// Returns an integer when this value is a JSON integer.
    public var integerValue: Int? { if case let .number(value) = self { Int(value) } else { nil } }
    /// Returns an object when this value is a JSON object.
    public var objectValue: [String: MobileRemoteCmuxJSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }
    /// Returns an array when this value is a JSON array.
    public var arrayValue: [MobileRemoteCmuxJSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    /// Creates a value from Foundation JSON while retaining integer spelling.
    /// - Parameter object: A JSON-compatible Foundation value.
    /// - Returns: The bounded recursive representation.
    /// - Throws: An error for unsupported Foundation values.
    public init(foundation object: Any) throws {
        switch object {
        case is NSNull: self = .null
        case let value as Bool: self = .boolean(value)
        case let value as NSNumber:
            self = .number(value.stringValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(try value.map(Self.init(foundation:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(Self.init(foundation:)))
        default: throw MobileRemoteCmuxJSONValueError.unsupportedFoundationValue
        }
    }

    /// Encodes a JSON value with standard JSON semantics.
    /// - Parameter encoder: Destination encoder.
    /// - Throws: Encoding failures.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .boolean(value): try container.encode(value)
        case let .number(value):
            guard let number = Decimal(string: value) else {
                throw MobileRemoteCmuxJSONValueError.invalidNumber
            }
            try container.encode(number)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Decodes a JSON value while rejecting non-JSON keyed shapes.
    /// - Parameter decoder: Source decoder.
    /// - Throws: Decoding failures.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int64.self) { self = .number(String(value)); return }
        if let value = try? container.decode(Decimal.self) { self = .number(String(describing: value)); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([MobileRemoteCmuxJSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: MobileRemoteCmuxJSONValue].self))
    }
}

/// Failures while converting or validating compatibility JSON.
public enum MobileRemoteCmuxJSONValueError: Error, Equatable, Sendable {
    /// Foundation supplied a non-JSON object.
    case unsupportedFoundationValue
    /// A numeric spelling could not be represented as `Decimal`.
    case invalidNumber
}
