import CmuxNextSettings
import Foundation

/// The diff page's display preferences as settings (coordinator decision
/// PAGE-PREFS): `diff.<key>` in cmux.json, read and written through
/// `cmux.diff.prefs.get` / `cmux.diff.prefs.set`, never web storage (the page
/// host pool clears web storage on reset). The keys and values are the ones
/// the page keeps (webviews/src/viewer-prefs.ts `sanitizeViewerPrefs`).
nonisolated enum DiffPrefKey {
    static let section = "diff"
    static let booleans: Set<String> = ["wordWrap", "wordDiffs", "lineNumbers", "showBackgrounds", "expandUnchanged"]
    static let choices: [String: Set<String>] = [
        "layout": ["split", "unified"],
        "diffIndicators": ["bars", "classic", "none"],
    ]
    /// Files collapsed from their header caret: `<repo root>\u{0}<path>`, at most 500.
    static let collapsedFiles = "collapsedFiles"
    static let maximumCollapsedFiles = 500

    static var all: [String] { (booleans.sorted() + choices.keys.sorted() + [collapsedFiles]) }

    static func path(_ key: String) -> [String] { [section, key] }

    /// Whether `value` is a valid value of `key` (null removes the setting).
    static func accepts(_ key: String, _ value: JSONValue) -> Bool {
        if value == .null { return all.contains(key) }
        if booleans.contains(key) { return value.boolValue != nil }
        if let allowed = choices[key] { return value.stringValue.map(allowed.contains) ?? false }
        guard key == collapsedFiles, let entries = value.arrayValue, entries.count <= maximumCollapsedFiles else { return false }
        return entries.allSatisfy { entry in
            guard let text = entry.stringValue else { return false }
            return text.contains("\u{0}") && text.utf8.count <= 4096
        }
    }

    /// The valid `diff.*` values of a settings object (others are dropped).
    static func sanitized(_ section: JSONValue?) -> [String: JSONValue] {
        guard let members = section?.objectValue else { return [:] }
        return members.filter { key, value in value != .null && accepts(key, value) }
    }
}

/// Where the diff prefs live.
protocol DiffPrefsStoring: AnyObject {
    /// The current prefs, `{key: value}`.
    func prefs() -> [String: JSONValue]
    /// Writes one pref; `.null` removes it (its default applies).
    func setPref(_ key: String, to value: JSONValue) async throws
}

/// The prefs in the settings store (cmux.json `diff.*`). A key the schema
/// lists is written through the schema setter; until the Settings lead adds
/// them, the raw file write the control socket uses for unlisted keys.
/// Writes are visible to `prefs()` at once, before the file watcher reloads.
final class SettingsDiffPrefs: DiffPrefsStoring {
    private let settings: () -> SettingsController?
    private var pending: [String: JSONValue] = [:]

    init(settings: @escaping () -> SettingsController?) {
        self.settings = settings
    }

    func prefs() -> [String: JSONValue] {
        var stored = DiffPrefKey.sanitized(settings()?.fileRoot[DiffPrefKey.section])
        for (key, value) in pending {
            if stored[key] ?? .null == value { pending[key] = nil }
            if value == .null { stored[key] = nil } else { stored[key] = value }
        }
        return stored
    }

    func setPref(_ key: String, to value: JSONValue) async throws {
        guard let settings = settings() else { throw Unavailable() }
        let path = DiffPrefKey.path(key)
        pending[key] = value
        if SettingsSchema.descriptor(for: path) != nil {
            let written: JSONValue? = value == .null ? .none : .some(value)
            try await settings.setSetting(at: path, to: written)
        } else {
            try await Self.write(value, at: path, in: settings.file)
        }
    }

    nonisolated struct Unavailable: Error, CustomStringConvertible {
        var description: String { "settings are not available" }
    }

    /// The config file is an actor: its blocking file IO runs off the main actor.
    private static func write(_ value: JSONValue, at path: [String], in file: CmuxConfigFile) async throws {
        if value == .null { try await file.remove(path) } else { try await file.set(value, at: path) }
    }
}
