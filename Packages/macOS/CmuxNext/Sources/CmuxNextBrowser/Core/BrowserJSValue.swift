import Foundation

/// A JSON-shaped value returned from page JavaScript. Engines convert their
/// native results (Foundation objects for WebKit, CDP JSON for CEF) into this,
/// so automation output is identical across engines.
public nonisolated enum BrowserJSValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BrowserJSValue])
    case object([String: BrowserJSValue])

    /// Converts a Foundation value from WebKit. Unknown types become `.null`.
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .number(date.timeIntervalSince1970 * 1000)
        case let array as [Any]:
            self = .array(array.map { BrowserJSValue(foundation: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { BrowserJSValue(foundation: $0) })
        default:
            self = .null
        }
    }

    /// Foundation representation, for passing arguments into WebKit.
    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
