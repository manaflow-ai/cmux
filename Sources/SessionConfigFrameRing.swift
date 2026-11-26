import Foundation

/// Per-window remembered frames keyed by display configuration, kept as an LRU
/// ring so monitor arrangements do not overwrite each other.
struct SessionConfigFrameRing: Codable, Sendable, Equatable {
    private(set) var entries: [SessionConfigFrameEntry]

    init(
        entries: [SessionConfigFrameEntry] = [],
        limit: Int = SessionPersistencePolicy.maxConfigFramesPerWindow
    ) {
        var seen = Set<String>()
        var result: [SessionConfigFrameEntry] = []
        for entry in entries.sorted(by: { $0.lastUsedAt > $1.lastUsedAt })
        where seen.insert(entry.signature).inserted {
            result.append(entry)
            if result.count >= limit { break }
        }
        self.entries = result
    }

    /// The remembered frame entry for `signature`, if present.
    func entry(for signature: String) -> SessionConfigFrameEntry? {
        entries.first { $0.signature == signature }
    }

    /// Returns a ring with `entry` replacing any existing entry for its
    /// signature, then trims to the most-recently-used `limit` entries.
    func upserting(
        _ entry: SessionConfigFrameEntry,
        limit: Int = SessionPersistencePolicy.maxConfigFramesPerWindow
    ) -> SessionConfigFrameRing {
        var next = entries.filter { $0.signature != entry.signature }
        next.append(entry)
        return SessionConfigFrameRing(entries: next, limit: limit)
    }
}
