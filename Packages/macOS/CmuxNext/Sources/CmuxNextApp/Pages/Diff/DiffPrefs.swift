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

    /// The display keys: `diff.<key>` schema rows (DiffViewerSettingsSchema), kept in cmux.json.
    static var displayKeys: [String] { booleans.sorted() + choices.keys.sorted() }
    /// Every pref the page reads and writes; `collapsedFiles` lives in the host's store
    /// (``DiffCollapsedFiles``), not in the settings.
    static var all: [String] { displayKeys + [collapsedFiles] }

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

    /// The valid `diff.*` display values of a settings object (others, `collapsedFiles` too, are
    /// dropped).
    static func sanitized(_ section: JSONValue?) -> [String: JSONValue] {
        guard let members = section?.objectValue else { return [:] }
        return members.filter { key, value in value != .null && displayKeys.contains(key) && accepts(key, value) }
    }
}

/// Where the diff prefs live.
protocol DiffPrefsStoring: AnyObject {
    /// The current prefs, `{key: value}`.
    func prefs() -> [String: JSONValue]
    /// Writes one pref; `.null` removes it (its default applies).
    func setPref(_ key: String, to value: JSONValue) async throws
}

/// The display prefs in the settings store (cmux.json `diff.*`, schema rows), written through the
/// schema setter only. Writes are visible to `prefs()` at once, before the file watcher reloads.
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
        let path = DiffPrefKey.path(key)
        guard DiffPrefKey.displayKeys.contains(key), SettingsSchema.descriptor(for: path) != nil else { throw NotASetting(key: key) }
        guard let settings = settings() else { throw Unavailable() }
        let written: JSONValue? = value == .null ? .none : .some(value)
        try await settings.setSetting(at: path, to: written, by: .caller("page"))
        // Only a write that succeeded shows before the file watcher reloads.
        pending[key] = value
    }

    nonisolated struct Unavailable: Error, CustomStringConvertible {
        var description: String { "settings are not available" }
    }

    /// A key with no schema row (`collapsedFiles` lives in ``DiffCollapsedFiles``).
    nonisolated struct NotASetting: Error, CustomStringConvertible {
        let key: String
        var description: String { "diff.\(key) is not a setting" }
    }
}
