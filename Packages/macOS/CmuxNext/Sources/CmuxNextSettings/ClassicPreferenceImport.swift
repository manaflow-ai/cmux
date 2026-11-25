import CmuxNextCompat
public import Foundation

/// Classic cmux settings its Settings window kept only in its preferences
/// (UserDefaults), never in `cmux.json`, so adopting the classic file misses
/// them (hq#1870 parity audit). Next ships under classic's bundle IDs, so the
/// app's defaults are classic's preferences on the same channel. Which keys,
/// how each reads and what `cmux.json` gets live in Rust (cmux-config
/// `migrations::classic`); this reads the domains.
nonisolated enum ClassicPreferenceImport {
    /// The preference keys to read from each domain and the marker key (`import.classic_preferences_pending`).
    static let layout = SettingsRust.answer("import.classic_preferences_pending", [:])

    /// The `cmux.json` paths already imported, so each is read once and a
    /// value the person later removes from `cmux.json` stays removed.
    static var importedKey: String { layout["marker"]?.stringValue ?? "classicPreferencesImported" }

    /// Whether a key is left to import once `done` are.
    static func pending(_ done: [String]) -> Bool {
        SettingsRust.answer("import.classic_preferences_pending", ["done": .array(done.map(JSONValue.string))])["pending"]?.boolValue ?? false
    }

    /// The classic preferences one domain holds, as JSON.
    static func source(_ defaults: UserDefaults) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for key in (layout["keys"]?.arrayValue ?? []).compactMap(\.stringValue) {
            if let object = defaults.object(forKey: key), let value = JSONValue(foundation: object) { out[key] = value }
        }
        return .object(out)
    }
}

extension SettingsController {
    /// `importClassicPreferences(from:marker:)` from classic's preferences:
    /// this channel's own (`marker`, the app's defaults) first, then the others.
    @discardableResult
    public func importClassicPreferences(marker: UserDefaults, bundleIdentifier: String? = Bundle.main.bundleIdentifier)
        async throws -> Bool {
        guard ClassicPreferenceImport.pending(marker.stringArray(forKey: ClassicPreferenceImport.importedKey) ?? []) else { return false }
        // A DEV build never derives its settings from another build's preferences (BuildStatePaths): its own only.
        let others = BuildIdentity(bundleID: bundleIdentifier, bundledTag: nil).isolatesSharedState ? []
            : ClassicShortcutImport.domains.filter { $0 != bundleIdentifier }.compactMap { UserDefaults(suiteName: $0) }
        return try await importClassicPreferences(from: [marker] + others, marker: marker)
    }

    /// Writes each classic preference to `cmux.json` from the first of
    /// `sources` that holds one, once per key (`marker` records it).
    /// A value `cmux.json` already has wins, and a value equal to next's
    /// default isn't written (`import.classic_preferences`). Returns whether it wrote.
    @discardableResult
    public func importClassicPreferences(from sources: [UserDefaults], marker: UserDefaults) async throws -> Bool {
        let done = marker.stringArray(forKey: ClassicPreferenceImport.importedKey) ?? []
        let request: JSONValue = ["done": .array(done.map(JSONValue.string)), "file": try await file.document(),
                                  "sources": .array(sources.map(ClassicPreferenceImport.source))]
        let reply = try SettingsRust.call("import.classic_preferences", request)
        let edits: [(path: [String], value: JSONValue)] = (reply["edits"]?.arrayValue ?? []).compactMap { edit in
            guard let path = edit["path"]?.arrayValue?.compactMap(\.stringValue), !path.isEmpty, let value = edit["value"] else { return nil }
            return (path, value)
        }
        let applied = edits.isEmpty ? [] : try await file.setUnset(edits)
        if !applied.isEmpty { await reloadAfterWrite() }
        marker.set((reply["done"]?.arrayValue ?? []).compactMap(\.stringValue), forKey: ClassicPreferenceImport.importedKey)
        return !applied.isEmpty
    }
}
