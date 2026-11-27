/// Durable map from a backed-up pairing to the server-verified team its backup
/// was last stored under.
///
/// A nil-team upload lets the SERVER pick the per-team Durable Object that
/// stores the record, and that resolution can drift over time. The presence
/// worker echoes the verified team on every upload; persisting it per pairing
/// lets a later delete tombstone route to the SAME backup the record actually
/// lives in instead of re-resolving nil at delete time.
public protocol PairedMacBackupTeamStoring: Sendable {
    /// The stored backup team for one pairing key, or nil when never echoed.
    func load(key: String) async -> String?

    /// Record the server-verified backup team for one pairing key.
    func save(_ teamID: String, key: String) async

    /// Record a whole restore snapshot's mappings in ONE persistence pass.
    /// Durable stores that rewrite their full state per `save` override this;
    /// the default forwards entry by entry.
    func saveAll(_ mappings: [PairedMacBackupTeamMapping]) async

    /// Drop one pairing's mapping (its tombstone reached the right backup).
    func remove(key: String) async

    /// Clear all mappings.
    func removeAll() async
}

/// One (mapping key → verified backup team) entry for a batched save.
public struct PairedMacBackupTeamMapping: Sendable {
    public let key: String
    public let teamID: String

    public init(key: String, teamID: String) {
        self.key = key
        self.teamID = teamID
    }
}

extension PairedMacBackupTeamStoring {
    /// Default batched save: one `save` per entry.
    public func saveAll(_ mappings: [PairedMacBackupTeamMapping]) async {
        for mapping in mappings {
            await save(mapping.teamID, key: mapping.key)
        }
    }
}

/// In-memory mapping store for tests and simple compositions.
public actor InMemoryPairedMacBackupTeamStore: PairedMacBackupTeamStoring {
    private var teams: [String: String] = [:]

    public init() {}

    public func load(key: String) async -> String? { teams[key] }
    public func save(_ teamID: String, key: String) async { teams[key] = teamID }
    public func remove(key: String) async { teams[key] = nil }
    public func removeAll() async { teams.removeAll() }
}
