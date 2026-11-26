import Foundation

/// A strongly-typed handle to a setting persisted in the cmux JSON config file.
///
/// `JSONKey` is one of two key flavors in ``CmuxSettings``; the other is
/// ``DefaultsKey``. Each flavor only matches its own store, so a
/// ``JSONConfigStore`` refuses a ``DefaultsKey`` at compile time and vice
/// versa. There are no runtime traps for wrong-store mismatches.
///
/// The key's ``id`` is used directly as the dotted JSON path. The matching
/// ``JSONPath`` value is precomputed at construction so reads and writes
/// never re-split the path string.
///
/// ```swift
/// public let automationSocketPassword = JSONKey<String>(
///     id: "automation.socketPassword",
///     defaultValue: ""
/// )
/// ```
public struct JSONKey<Value: SettingCodable>: Sendable, Equatable {
    /// The dotted identifier (also the JSON path inside the cmux config file).
    public let id: String

    /// The value returned when the file is missing or the path is absent.
    public let defaultValue: Value

    /// The precomputed path matching ``id``. Used by ``JSONConfigStore`` to
    /// walk the JSON tree without re-splitting per call.
    public let path: JSONPath

    /// Creates a JSON-backed setting key.
    ///
    /// - Parameters:
    ///   - id: The dotted identifier, which is also the JSON path.
    ///   - defaultValue: The fallback when the file is missing or the path
    ///     is absent.
    public init(id: String, defaultValue: Value) {
        self.id = id
        self.defaultValue = defaultValue
        self.path = JSONPath(dottedPath: id)
    }
}
