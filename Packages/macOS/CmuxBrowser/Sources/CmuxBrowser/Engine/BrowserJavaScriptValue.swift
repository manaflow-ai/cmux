import CoreFoundation
import Foundation

/// A Sendable copy of a JavaScript evaluation result.
public enum BrowserJavaScriptValue: Equatable, Sendable {
    /// JavaScript `undefined` or a missing remote value.
    case undefined

    /// JavaScript `null`.
    case null

    /// A JavaScript boolean.
    case bool(Bool)

    /// A JavaScript number.
    case number(Double)

    /// A JavaScript string.
    case string(String)

    /// A JavaScript array containing transferable values.
    case array([BrowserJavaScriptValue])

    /// A JavaScript object with string keys and transferable values.
    case object([String: BrowserJavaScriptValue])

    /// Copies a Foundation value returned by WebKit into a Sendable representation.
    ///
    /// - Parameter foundationValue: A WebKit JavaScript result.
    /// - Throws: ``BrowserEngineSessionError/unsupportedJavaScriptValue`` when the result is not transferable.
    public init(foundationValue: Any?) throws {
        switch foundationValue {
        case nil:
            self = .undefined
        case is NSNull:
            self = .null
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = try .array(values.map { try BrowserJavaScriptValue(foundationValue: $0) })
        case let values as [String: Any]:
            self = try .object(values.mapValues { try BrowserJavaScriptValue(foundationValue: $0) })
        default:
            throw BrowserEngineSessionError.unsupportedJavaScriptValue
        }
    }

    /// The Foundation representation expected by existing browser automation callers.
    @MainActor
    public var foundationValue: Any? {
        switch self {
        case .undefined:
            return nil
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }
}
