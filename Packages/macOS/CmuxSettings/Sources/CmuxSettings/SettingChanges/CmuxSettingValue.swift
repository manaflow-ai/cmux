import Foundation

/// A JSON value carried by a setting change, such as the `set` value or a
/// `cycle` entry of a `"type": "setting"` action.
///
/// It exists so setting changes can be `Hashable` and `Sendable` like the
/// rest of the action registry, and converts to and from the Foundation
/// objects `JSONSerialization` and ``JSONConfigStore`` work with.
public enum CmuxSettingValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CmuxSettingValue])
    case object([String: CmuxSettingValue])

    /// Converts a `JSONSerialization` object. Returns nil for values JSON
    /// can't represent, including non-finite numbers.
    public init?(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let value = number.doubleValue
                guard value.isFinite else { return nil }
                self = .number(value)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [CmuxSettingValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = CmuxSettingValue(jsonObject: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: CmuxSettingValue] = [:]
            for (key, element) in dictionary {
                guard let value = CmuxSettingValue(jsonObject: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    /// Parses a command-line value the way `cmux config set` does: valid JSON
    /// (`true`, `1.4`, `"text"`, `[...]`, `{...}`) keeps its type, and any
    /// other text is taken as a plain string, so `cmux config set
    /// app.appearance dark` works without shell-quoting JSON.
    public init(commandLineArgument raw: String) {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let value = CmuxSettingValue(jsonObject: object) {
            self = value
        } else {
            self = .string(raw)
        }
    }

    /// The Foundation representation `JSONSerialization` accepts. Integral
    /// numbers become integers so `2` round-trips as `2`, not `2.0`.
    public var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return NSNumber(value: value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                return NSNumber(value: Int64(value))
            }
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.jsonObject)
        case .object(let values):
            return values.mapValues(\.jsonObject)
        }
    }

    /// Compact JSON text for messages and CLI output.
    public var jsonText: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}

extension CmuxSettingValue: Codable {
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
        } else if let value = try? container.decode([CmuxSettingValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CmuxSettingValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}
