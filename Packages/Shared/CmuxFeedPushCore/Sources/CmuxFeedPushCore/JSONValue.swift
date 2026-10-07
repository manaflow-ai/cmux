import Foundation

/// A JSON value that is Sendable (op params cross actors).
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([JSONValue])
    case object([String: JSONValue])

    var foundation: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .int(let value): value
        case .array(let value): value.map(\.foundation)
        case .object(let value): value.mapValues(\.foundation)
        }
    }

    /// Converts Foundation JSON (strings, booleans, integers, arrays,
    /// objects). Nil for anything else, so a malformed value is never sent.
    public init?(foundation value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue); return }
            guard let int = Int(exactly: value.doubleValue) else { return nil }
            self = .int(int)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as [Any]:
            var items: [JSONValue] = []
            for item in value {
                guard let converted = JSONValue(foundation: item) else { return nil }
                items.append(converted)
            }
            self = .array(items)
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in value {
                guard let converted = JSONValue(foundation: item) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        default: return nil
        }
    }
}
