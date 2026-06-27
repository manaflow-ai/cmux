import CmuxSettings
import Foundation
import os

nonisolated private let shortcutSettingsFileSectionParserLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

/// Stateless parser for the `shortcuts` section of a cmux settings JSON root.
///
/// Projects the decoded `shortcuts` object into a ``ResolvedSettingsSnapshot``:
/// the keyboard-shortcut bindings (top-level entries plus the nested `bindings`
/// map), the `showModifierHoldHints` toggle, and the `shortcuts.when`
/// focus-context overrides. It reuses the `CmuxSettings` decoders that own the
/// shortcut value shapes (``StoredShortcut/parseSettingsFileBinding(_:action:)``
/// for bindings, ``ShortcutWhenClause/parse(_:)`` for `when` clauses) and the
/// shared ``SettingsFileProjectionEngine`` for JSON scalar coercion and
/// invalid-setting logging. It holds no paths and touches no filesystem;
/// ``SettingsFileParser`` constructs it with its projection engine and forwards
/// the section once per source file.
struct ShortcutSettingsFileSectionParser {
    private let projection: SettingsFileProjectionEngine

    init(projection: SettingsFileProjectionEngine) {
        self.projection = projection
    }

    func parse(
        _ value: Any,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let section = value as? [String: Any] else {
            logInvalid("shortcuts", sourcePath: sourcePath)
            return
        }

        var bindings = section["bindings"] as? [String: Any] ?? [:]
        if let value = jsonBool(section["showModifierHoldHints"]) {
            snapshot.managedUserDefaults[SettingCatalog().shortcuts.showModifierHoldHints.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("showModifierHoldHints") {
            logInvalid("shortcuts.showModifierHoldHints", sourcePath: sourcePath)
        }
        for (key, rawValue) in section where key != "bindings" && key != "showModifierHoldHints" && key != "when" {
            bindings[key] = rawValue
        }

        for (rawAction, rawBinding) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                shortcutSettingsFileSectionParserLogger.warning("ignoring unknown shortcut action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let shortcut = StoredShortcut.parseSettingsFileBinding(rawBinding, action: action) else {
                shortcutSettingsFileSectionParserLogger.warning("ignoring invalid shortcut binding for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.shortcuts[action] = shortcut
        }

        parseWhenClauses(section["when"], sourcePath: sourcePath, snapshot: &snapshot)
    }

    /// Parses the optional `shortcuts.when` map — `{ "<actionId>": "<predicate>" }`
    /// — into per-action ``ShortcutWhenClause`` overrides. A binding's `when`
    /// clause gates it to a focus context, letting the same keystroke drive
    /// different actions in different contexts (e.g. `⌃1` selects a workspace
    /// unless the sidebar is focused). Invalid entries are logged and skipped.
    private func parseWhenClauses(
        _ rawValue: Any?,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let rawValue else { return }
        guard let whenSection = rawValue as? [String: Any] else {
            logInvalid("shortcuts.when", sourcePath: sourcePath)
            return
        }
        for (rawAction, rawClause) in whenSection {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                shortcutSettingsFileSectionParserLogger.warning("ignoring shortcuts.when for unknown action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let expression = jsonString(rawClause),
                  let clause = ShortcutWhenClause.parse(expression) else {
                shortcutSettingsFileSectionParserLogger.warning("ignoring invalid shortcuts.when clause for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.whenClauses[action] = clause
        }
    }

    // The domain-agnostic projection engine (JSON scalar coercion, invalid-setting
    // logging) lives in `CmuxSettings`. This parser holds the same instance its
    // owner (`SettingsFileParser`) holds and forwards the shared `logInvalid`/
    // `json*` helpers to it so the moved call sites stay unchanged.
    private func logInvalid(_ path: String, sourcePath: String) {
        projection.logInvalid(path, sourcePath: sourcePath)
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        projection.jsonString(rawValue)
    }

    private func jsonBool(_ rawValue: Any?) -> Bool? {
        projection.jsonBool(rawValue)
    }
}
