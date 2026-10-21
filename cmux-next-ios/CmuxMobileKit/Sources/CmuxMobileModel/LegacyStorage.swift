import Foundation

/// The one-time move off the storage names builds up to 1.2.0 used (the app was called
/// cnx then), so an update keeps the account, team, settings and Chief outboxes.
///
/// Runs at launch before anything reads them. Settings: every `cnx.` UserDefaults key
/// becomes the same key under `cmuxMobile.` unless that key is already set; the old key
/// is removed. Files in Application Support: the Chief outboxes and the live snapshot
/// folder are renamed unless the new name exists. The Keychain device ids move in
/// `DeviceIdentity` (CmuxMobileLive). Idempotent: a second run finds nothing to move.
public enum LegacyStorage {
    static let legacyPrefix = "cnx."
    static let prefix = "cmuxMobile."
    /// Application Support names: old to new.
    static let files: [(String, String)] = [
        ("cnx-chief-outbox.json", "cmux-mobile-chief-outbox.json"),
        ("cnx-cloud-chief-outbox.json", "cmux-mobile-cloud-chief-outbox.json"),
        ("cnx-live", "cmux-mobile-live"),
    ]

    public static func migrate(defaults: UserDefaults = .standard,
                               applicationSupport: URL? = FileManager.default.urls(
                                   for: .applicationSupportDirectory, in: .userDomainMask).first) {
        migrateDefaults(defaults)
        if let applicationSupport { migrateFiles(in: applicationSupport) }
    }

    /// Returns the keys it moved (old names).
    @discardableResult
    static func migrateDefaults(_ defaults: UserDefaults) -> [String] {
        var moved: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(legacyPrefix) {
            let renamed = prefix + key.dropFirst(legacyPrefix.count)
            if defaults.object(forKey: renamed) == nil { defaults.set(renamedRecord(value), forKey: renamed) }
            defaults.removeObject(forKey: key)
            moved.append(key)
        }
        return moved.sorted()
    }

    /// A signed-out account's record (`AccountPreferences`, `cnx.account.<user id>`) holds
    /// that account's preferences under their own keys: those move to the new names too.
    static func renamedRecord(_ value: Any) -> Any {
        guard let record = value as? [String: Any] else { return value }
        var out: [String: Any] = [:]
        for (key, inner) in record {
            let renamed = key.hasPrefix(legacyPrefix) ? prefix + key.dropFirst(legacyPrefix.count) : key
            if out[renamed] == nil || renamed == key { out[renamed] = inner }
        }
        return out
    }

    static func migrateFiles(in directory: URL, fileManager: FileManager = .default) {
        for (old, new) in files {
            let from = directory.appending(path: old)
            let to = directory.appending(path: new)
            guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.moveItem(at: from, to: to)
        }
    }
}
