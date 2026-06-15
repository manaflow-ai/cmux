import Foundation

/// One row of `cmux settings list` / the result of `cmux settings get`.
public struct SettingRow: Sendable, Equatable {
    public let id: String
    public let backend: SettingBackend
    public let valueType: SettingValueType
    public let isSecret: Bool
    /// The current value (redacted when `isSecret`).
    public let value: SettingJSONValue
    public let defaultValue: SettingJSONValue
    /// Whether a stored override exists (vs. falling back to the default).
    public let isOverridden: Bool

    /// The value's source label for human output: `set` when overridden, else
    /// `default`.
    public var source: String { isOverridden ? "set" : "default" }
}

/// The full metadata for `cmux settings describe <key>`.
public struct SettingDescription: Sendable, Equatable {
    public let id: String
    public let backend: SettingBackend
    public let type: String
    /// The accepted raw values for an enum setting, else `nil`.
    public let allowedValues: [String]?
    public let isSecret: Bool
    public let value: SettingJSONValue
    public let defaultValue: SettingJSONValue
    public let isOverridden: Bool
    /// The catalog section (the dotted-id prefix, e.g. `app`).
    public let section: String
}

/// A portable settings snapshot for `export` / `import`.
///
/// Wire form is `{ "settings": { "<id>": <value>, … } }`. Secret keys are
/// omitted on export so a profile never carries a credential.
public struct SettingsDocument: Sendable, Equatable {
    public var settings: [String: SettingJSONValue]

    public init(settings: [String: SettingJSONValue]) {
        self.settings = settings
    }

    /// Canonical JSON text (objects sorted by key) suitable for writing to a
    /// file and re-importing.
    public var jsonText: String {
        SettingJSONValue.object([
            "settings": .object(settings),
        ]).jsonText
    }

    /// Parses an export document. Accepts either the wrapped `{ "settings": {…} }`
    /// form or a bare `{ "<id>": <value> }` map.
    public static func parse(_ text: String) throws -> SettingsDocument {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw SettingsControlError.importFailed(errors: ["document is not valid JSON"])
        }
        let root = SettingJSONValue(jsonObject: object)
        let settingsValue: SettingJSONValue
        if case let .object(top) = root, let nested = top["settings"] {
            settingsValue = nested
        } else {
            settingsValue = root
        }
        guard case let .object(map) = settingsValue else {
            throw SettingsControlError.importFailed(errors: ["expected a JSON object of settings"])
        }
        return SettingsDocument(settings: map)
    }
}

/// One row of `cmux settings shortcuts list` / the result of `shortcuts get`.
public struct ShortcutRow: Sendable, Equatable {
    /// The action id (e.g. `newTab`).
    public let action: String
    /// The current binding as a config string (e.g. `cmd+t`, `ctrl+b c`, or
    /// `none` when unbound).
    public let binding: String
    /// The built-in default binding as a config string (`none` when the action
    /// has no default).
    public let defaultBinding: String
    /// Whether the binding is a user override (vs. the default).
    public let isOverridden: Bool
}
