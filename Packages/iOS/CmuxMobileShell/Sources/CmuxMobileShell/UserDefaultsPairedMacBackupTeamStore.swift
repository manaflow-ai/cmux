public import Foundation

/// UserDefaults-backed backup-team mapping for production. Values are only
/// team ids keyed by Stack account + pairing id; no routes or hostnames are
/// stored here. Entries are removed when a pairing's delete tombstone reaches
/// its backup — but only when THIS device sends it, so retention is BOUNDED:
/// mappings for records deleted from other devices, abandoned accounts, and
/// expired server rows would otherwise accumulate (and be deserialized and
/// rewritten on every route mirror) forever. When the cap is exceeded the
/// oldest-saved mappings are evicted; losing one degrades that pairing's next
/// forget to the parked (echo-recovered) path.
public actor UserDefaultsPairedMacBackupTeamStore: PairedMacBackupTeamStoring {
    private let defaults: UserDefaults
    private let key: String
    private let orderKey: String

    /// Upper bound on retained mappings; mirrors the discovery snapshot's
    /// 256-binding wire cap with headroom for multi-team copies.
    static let mappingCap = 512

    /// Create a durable backup-team mapping store.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.pairedMacBackup.backupTeams.v1"
    ) {
        self.defaults = defaults
        self.key = key
        self.orderKey = "\(key).order"
    }

    /// The stored backup team for one pairing key, or nil when never echoed.
    public func load(key mapKey: String) async -> String? {
        let all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return all[mapKey]
    }

    /// Record the server-verified backup team for one pairing key.
    public func save(_ teamID: String, key mapKey: String) async {
        await saveAll([PairedMacBackupTeamMapping(key: mapKey, teamID: teamID)])
    }

    /// Record a whole restore snapshot's mappings in ONE read-modify-write of
    /// the persisted dictionary and ordering, instead of a full-state rewrite
    /// per record.
    public func saveAll(_ mappings: [PairedMacBackupTeamMapping]) async {
        guard !mappings.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        var order = defaults.stringArray(forKey: orderKey) ?? []
        let touched = Set(mappings.map(\.key))
        // Move-to-newest so eviction age tracks the LAST save.
        order.removeAll { touched.contains($0) }
        for mapping in mappings {
            all[mapping.key] = mapping.teamID
            order.append(mapping.key)
        }
        // Repair any drift between the dictionary and the order list
        // (pre-order builds stored only the dictionary).
        order.removeAll { all[$0] == nil }
        let ordered = Set(order)
        for known in all.keys where !ordered.contains(known) {
            order.insert(known, at: 0)
        }
        while order.count > Self.mappingCap {
            let evicted = order.removeFirst()
            all.removeValue(forKey: evicted)
        }
        defaults.set(all, forKey: key)
        defaults.set(order, forKey: orderKey)
    }

    /// Drop one pairing's mapping.
    public func remove(key mapKey: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all.removeValue(forKey: mapKey) != nil else { return }
        var order = defaults.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == mapKey }
        if all.isEmpty {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: orderKey)
        } else {
            defaults.set(all, forKey: key)
            defaults.set(order, forKey: orderKey)
        }
    }

    /// Clear all mappings.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: orderKey)
    }
}
