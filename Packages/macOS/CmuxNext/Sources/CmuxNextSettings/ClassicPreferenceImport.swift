public import Foundation

/// Classic cmux settings its Settings window kept only in its preferences
/// (UserDefaults), never in `cmux.json`, so adopting the classic file misses
/// them (hq#1870 parity audit). Next ships under classic's bundle IDs, so the
/// app's defaults are classic's preferences on the same channel.
nonisolated enum ClassicPreferenceImport {
    nonisolated struct Entry: Sendable {
        let next: [String]
        /// An older next key for the same value: imported under it already, or set in `cmux.json`, counts.
        var legacy: [String]? = nil
        /// The value one classic domain holds, nil when it holds none.
        let read: @Sendable (UserDefaults) -> JSONValue?
    }

    /// The `cmux.json` paths already imported, so each is read once and a
    /// value the person later removes from `cmux.json` stays removed.
    static let importedKey = "classicPreferencesImported"

    static let entries: [Entry] = [
        // Classic's effective value: a disabled browser opened every link outside.
        Entry(next: LinkRouting.openPath, legacy: LinkRouting.legacyOpenPath) { defaults in
            if defaults.bool(forKey: "browserDisabledOverride") { return .bool(false) }
            return (defaults.object(forKey: "browserOpenTerminalLinksInCmuxBrowser") as? Bool).map(JSONValue.bool)
        },
        Entry(next: LinkRouting.hostsPath) { lines(defaults: $0, key: "browserHostWhitelist") },
        Entry(next: LinkRouting.rulesPath) { lines(defaults: $0, key: "browserExternalOpenPatterns") },
    ]

    /// Classic's one-per-line text, or the array older releases left.
    static func lines(defaults: UserDefaults, key: String) -> JSONValue? {
        let raw: JSONValue
        switch defaults.object(forKey: key) {
        case let text as String: raw = .string(text)
        case let items as [String]: raw = .array(items.map(JSONValue.string))
        default: return nil
        }
        return LinkRouting.lines(raw).map { .array($0.map(JSONValue.string)) }
    }
}

extension SettingsController {
    /// `importClassicPreferences(from:marker:)` from classic's preferences:
    /// this channel's own (`marker`, the app's defaults) first, then the others.
    @discardableResult
    public func importClassicPreferences(marker: UserDefaults, bundleIdentifier: String? = Bundle.main.bundleIdentifier)
        async throws -> Bool {
        let others = ClassicShortcutImport.domains.filter { $0 != bundleIdentifier }.compactMap { UserDefaults(suiteName: $0) }
        return try await importClassicPreferences(from: [marker] + others, marker: marker)
    }

    /// Writes each `ClassicPreferenceImport` value to `cmux.json` from the
    /// first of `sources` that holds one, once per key (`marker` records it).
    /// A value `cmux.json` already has wins, and a value equal to next's
    /// default isn't written. Returns whether it wrote.
    @discardableResult
    public func importClassicPreferences(from sources: [UserDefaults], marker: UserDefaults) async throws -> Bool {
        var done = Set(marker.stringArray(forKey: ClassicPreferenceImport.importedKey) ?? [])
        var edits: [(path: [String], value: JSONValue?)] = []
        for entry in ClassicPreferenceImport.entries {
            let id = entry.next.joined(separator: ".")
            let legacyID = entry.legacy?.joined(separator: ".")
            guard !done.contains(id), legacyID.map(done.contains) != true else { continue }
            done.insert(id)
            if let legacy = entry.legacy, try await file.value(at: legacy) != nil { continue }
            guard let value = sources.lazy.compactMap(entry.read).first, try await file.value(at: entry.next) == nil,
                  let descriptor = SettingsSchema.all.first(where: { $0.path == entry.next }),
                  descriptor.accepts(value), value != descriptor.defaultValue else { continue }
            edits.append((entry.next, value))
        }
        if !edits.isEmpty {
            try await file.apply(edits)
            await reloadAfterWrite()
        }
        marker.set(done.sorted(), forKey: ClassicPreferenceImport.importedKey)
        return !edits.isEmpty
    }
}
