import CmuxFoundation
import Foundation
import os

/// Domain-agnostic projection engine for cmux settings-file parsing.
///
/// Projects untyped JSON `[String: Any]` sections into typed
/// ``ManagedSettingsValue`` entries on a ``ManagedSettingsProjecting`` target via
/// the table-driven ``SettingsFileBooleanMapping`` / ``SettingsFileStringMapping``
/// / ``SettingsFileStringArrayMapping`` descriptors. It owns the shared JSON
/// scalar coercion (delegating to ``CmuxFoundation/JSONScalar``) and the
/// invalid-setting logging that the per-domain parsers reuse, so a parser holds
/// one instance and forwards the shared helpers to it. Stateless apart from its
/// logger.
public struct SettingsFileProjectionEngine {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

    public init() {}

    /// Applies each boolean mapping whose JSON key holds a coercible boolean,
    /// logging an invalid-setting warning for a present but uncoercible value
    /// when the mapping declares an `invalidPath`.
    public func applyBooleanSettings<Target: ManagedSettingsProjecting>(
        _ settings: [SettingsFileBooleanMapping],
        from section: [String: Any],
        sourcePath: String,
        into target: inout Target
    ) {
        for setting in settings {
            if let value = jsonBool(section[setting.jsonKey]) {
                target.projectManagedDefault(.bool(value), forKey: setting.defaultsKey)
            } else if let invalidPath = setting.invalidPath, section.keys.contains(setting.jsonKey) {
                logInvalid(invalidPath, sourcePath: sourcePath)
            }
        }
    }

    /// Applies each string mapping whose JSON key holds a coercible string.
    public func applyStringSettings<Target: ManagedSettingsProjecting>(
        _ settings: [SettingsFileStringMapping],
        from section: [String: Any],
        into target: inout Target
    ) {
        for setting in settings {
            if let raw = jsonString(section[setting.jsonKey]) {
                target.projectManagedDefault(.string(raw), forKey: setting.defaultsKey)
            }
        }
    }

    /// Applies each string-array mapping whose JSON key holds a coercible string
    /// array, trimming whitespace, dropping empty entries, and joining the
    /// survivors with newlines. Logs an invalid-setting warning for a present but
    /// uncoercible value.
    public func applyNormalizedStringArraySettings<Target: ManagedSettingsProjecting>(
        _ settings: [SettingsFileStringArrayMapping],
        from section: [String: Any],
        sourcePath: String,
        into target: inout Target
    ) {
        for setting in settings {
            if let values = jsonStringArray(section[setting.jsonKey]) {
                let normalized = values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                target.projectManagedDefault(.string(normalized.joined(separator: "\n")), forKey: setting.defaultsKey)
            } else if section.keys.contains(setting.jsonKey) {
                logInvalid(setting.invalidPath, sourcePath: sourcePath)
            }
        }
    }

    /// Logs that the setting at `path` (parsed from `sourcePath`) held an invalid
    /// value and was ignored. Shared by every per-domain parser.
    public func logInvalid(_ path: String, sourcePath: String) {
        logger.warning("ignoring invalid setting '\(path, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
    }

    // JSON scalar coercion narrows untyped `Any?` parsed values to typed Swift
    // values; the coercion rules live in `CmuxFoundation.JSONScalar`. These thin
    // adapters keep the per-domain parsers' call sites unchanged.

    /// Coerces a parsed JSON value to a `String`, per ``CmuxFoundation/JSONScalar``.
    public func jsonString(_ rawValue: Any?) -> String? {
        JSONScalar(rawValue).string
    }

    /// Coerces a parsed JSON value to a `Bool`, per ``CmuxFoundation/JSONScalar``.
    public func jsonBool(_ rawValue: Any?) -> Bool? {
        JSONScalar(rawValue).bool
    }

    /// Coerces a parsed JSON value to an `Int`, per ``CmuxFoundation/JSONScalar``.
    public func jsonInt(_ rawValue: Any?) -> Int? {
        JSONScalar(rawValue).int
    }

    /// Coerces a parsed JSON value to a `Double`, per ``CmuxFoundation/JSONScalar``.
    public func jsonDouble(_ rawValue: Any?) -> Double? {
        JSONScalar(rawValue).double
    }

    /// Coerces a parsed JSON value to a `[String]`, per ``CmuxFoundation/JSONScalar``.
    public func jsonStringArray(_ rawValue: Any?) -> [String]? {
        JSONScalar(rawValue).stringArray
    }
}
