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
        guard let foundationValue else {
            self = .undefined
            return
        }
        if foundationValue is NSNull {
            self = .null
            return
        }
        if let value = foundationValue as? NSNumber {
            self = CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
            return
        }
        if let value = foundationValue as? String {
            self = .string(value)
            return
        }
        if let values = foundationValue as? [Any] {
            self = try .array(values.map { try BrowserJavaScriptValue(foundationValue: $0) })
            return
        }
        if let values = foundationValue as? [String: Any] {
            self = try .object(values.mapValues { try BrowserJavaScriptValue(foundationValue: $0) })
            return
        }
        throw BrowserEngineSessionError.unsupportedJavaScriptValue
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
