import Foundation

/// Repository for the two `UserDefaults`-persisted managed-settings caches the
/// settings-file store keeps: the imported managed-defaults snapshot (the
/// administrator-pushed values cmux.json last applied) and the pre-managed
/// value backups (originals captured before a managed default overrode a key).
///
/// Both caches are stored as JSON-encoded blobs under fixed keys, mirroring the
/// legacy `CmuxSettingsFileStore` persistence verbatim so existing users' caches
/// keep decoding. The repository does pure load/save only; the app-side store
/// keeps the legacy-migration tail (deriving snapshot entries from retired
/// default keys) and the retired-key cleanup, since those reference
/// app-target setting catalogs the package cannot see.
///
/// Isolation: a `Sendable` struct, not an actor. The settings-file store reads
/// and writes these caches synchronously inside its own reload/apply turns, the
/// struct holds no mutable state, and `UserDefaults` is documented thread-safe.
public struct ManagedDefaultsRepository: Sendable {
    /// Defaults key for the JSON-encoded imported-managed-defaults snapshot.
    private static let importedManagedDefaultsDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    /// Defaults key for the JSON-encoded pre-managed value backups.
    private static let backupsDefaultsKey = "cmux.settingsFile.backups.v1"

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a repository reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The imported managed-defaults snapshot decoded from `UserDefaults`, or an
    /// empty map when none was stored or decoding fails.
    public func loadImportedManagedDefaults() -> [String: ManagedSettingsValue] {
        guard let data = defaults.data(forKey: Self.importedManagedDefaultsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: ManagedSettingsValue].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Persists the imported managed-defaults snapshot, removing the key when the
    /// snapshot is empty.
    public func saveImportedManagedDefaults(_ imported: [String: ManagedSettingsValue]) {
        guard !imported.isEmpty else {
            defaults.removeObject(forKey: Self.importedManagedDefaultsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(imported) else { return }
        defaults.set(data, forKey: Self.importedManagedDefaultsDefaultsKey)
    }

    /// The pre-managed value backups decoded from `UserDefaults`, or an empty map
    /// when none were stored or decoding fails.
    public func loadBackups() -> [String: ManagedDefaultBackupValue] {
        guard let data = defaults.data(forKey: Self.backupsDefaultsKey),
              let backups = try? JSONDecoder().decode([String: ManagedDefaultBackupValue].self, from: data) else {
            return [:]
        }
        return backups
    }

    /// Persists the pre-managed value backups, removing the key when empty.
    public func saveBackups(_ backups: [String: ManagedDefaultBackupValue]) {
        if backups.isEmpty {
            defaults.removeObject(forKey: Self.backupsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(backups) else { return }
        defaults.set(data, forKey: Self.backupsDefaultsKey)
    }
}
