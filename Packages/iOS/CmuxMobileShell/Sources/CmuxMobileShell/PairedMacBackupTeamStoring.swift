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

    /// Drop one pairing's mapping (its tombstone reached the right backup).
    func remove(key: String) async

    /// Clear all mappings.
    func removeAll() async
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
