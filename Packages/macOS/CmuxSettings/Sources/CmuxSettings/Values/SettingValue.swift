import Foundation

/// Sendable, type-erased value used by schema-driven settings editors.
public enum SettingValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case text(String)
    case data(Data)
    case array([SettingValue])
    case object([String: SettingValue])

    /// A stable editable representation for text-based controls.
    public var editingText: String {
        switch self {
        case .boolean(let value):
            value ? "true" : "false"
        case .integer(let value):
            String(value)
        case .number(let value):
            String(value)
        case .text(let value):
            value
        case .data(let value):
            value.base64EncodedString()
        case .array, .object:
            Self.jsonText(encodedRepresentation) ?? ""
        }
    }

    /// Parses text using the receiver's existing storage shape.
    public func replacingValue(with text: String) throws -> SettingValue {
        switch self {
        case .boolean:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return .boolean(true)
            case "false", "0", "no", "off": return .boolean(false)
            default: throw SettingValueError.invalidBoolean(text)
            }
        case .integer:
            guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SettingValueError.invalidInteger(text)
            }
            return .integer(value)
        case .number:
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  value.isFinite else {
                throw SettingValueError.invalidNumber(text)
            }
            return .number(value)
        case .text:
            return .text(text)
        case .data:
            guard let value = Data(base64Encoded: text) else {
                throw SettingValueError.invalidData
            }
            return .data(value)
        case .array:
            guard let value = Self.value(fromJSONText: text), case .array = value else {
                throw SettingValueError.invalidJSON
            }
            return value
        case .object:
            guard let value = Self.value(fromJSONText: text), case .object = value else {
                throw SettingValueError.invalidJSON
            }
            return value
        }
    }

    init?(encodedRepresentation raw: Any) {
        switch raw {
        case let value as Bool:
            self = .boolean(value)
        case let value as Int:
            self = .integer(value)
        case let value as Double:
            self = .number(value)
        case let value as Float:
            self = .number(Double(value))
        case let value as String:
            self = .text(value)
        case let value as Data:
            self = .data(value)
        case let values as [Any]:
            var converted: [SettingValue] = []
            converted.reserveCapacity(values.count)
            for value in values {
                guard let item = SettingValue(encodedRepresentation: value) else { return nil }
                converted.append(item)
            }
            self = .array(converted)
        case let values as [String: Any]:
            var converted: [String: SettingValue] = [:]
            converted.reserveCapacity(values.count)
            for (key, value) in values {
                guard let item = SettingValue(encodedRepresentation: value) else { return nil }
                converted[key] = item
            }
            self = .object(converted)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .boolean(value.boolValue)
            } else if value.doubleValue.rounded() == value.doubleValue {
                self = .integer(value.intValue)
            } else {
                self = .number(value.doubleValue)
            }
        default:
            return nil
        }
    }

    var encodedRepresentation: Any {
        switch self {
        case .boolean(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .text(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.encodedRepresentation)
        case .object(let values): values.mapValues(\.encodedRepresentation)
        }
    }

    private static func value(fromJSONText text: String) -> SettingValue? {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let value = SettingValue(encodedRepresentation: raw) else { return nil }
        return value
    }

    private static func jsonText(_ raw: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(
                  withJSONObject: raw,
                  options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Validation failure from a schema-driven settings editor.
public enum SettingValueError: Error, Sendable, Equatable {
    case unsupportedValue(String)
    case invalidBoolean(String)
    case invalidInteger(String)
    case invalidNumber(String)
    case invalidData
    case invalidJSON
}
