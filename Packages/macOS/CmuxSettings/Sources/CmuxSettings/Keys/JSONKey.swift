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

    /// Display metadata used by CLI and documentation surfaces.
    public let metadata: SettingMetadata

    /// Alternate cmux.json paths that should be shown with this setting.
    public let jsonAliases: [String]

    /// Creates a JSON-backed setting key.
    ///
    /// - Parameters:
    ///   - id: The dotted identifier, which is also the JSON path.
    ///   - defaultValue: The fallback when the file is missing or the path
    ///     is absent.
    ///   - title: Optional display title for CLI/docs output.
    ///   - description: Optional explanatory text for CLI/docs output.
    ///   - jsonAliases: Alternate cmux.json paths that should be shown.
    public init(
        id: String,
        defaultValue: Value,
        title: String? = nil,
        description: String? = nil,
        jsonAliases: [String] = []
    ) {
        self.id = id
        self.defaultValue = defaultValue
        self.path = JSONPath(dottedPath: id)
        self.metadata = SettingMetadata(id: id, title: title, description: description)
        self.jsonAliases = jsonAliases
    }
}
