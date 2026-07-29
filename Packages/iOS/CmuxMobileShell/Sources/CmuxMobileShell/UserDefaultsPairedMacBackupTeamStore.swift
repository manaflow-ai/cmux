public import Foundation

/// UserDefaults-backed backup-team mapping for production. Values are only
/// team ids keyed by Stack account + pairing id; no routes or hostnames are
/// stored here. Entries are removed when a pairing's delete tombstone reaches
/// its backup, so the map tracks live backed-up pairings only.
public actor UserDefaultsPairedMacBackupTeamStore: PairedMacBackupTeamStoring {
    private let defaults: UserDefaults
    private let key: String

    /// Create a durable backup-team mapping store.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.pairedMacBackup.backupTeams.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// The stored backup team for one pairing key, or nil when never echoed.
    public func load(key mapKey: String) async -> String? {
        let all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return all[mapKey]
    }

    /// Record the server-verified backup team for one pairing key.
    public func save(_ teamID: String, key mapKey: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[mapKey] = teamID
        defaults.set(all, forKey: key)
    }

    /// Drop one pairing's mapping.
    public func remove(key mapKey: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all.removeValue(forKey: mapKey) != nil else { return }
        if all.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(all, forKey: key)
        }
    }

    /// Clear all mappings.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }
}
