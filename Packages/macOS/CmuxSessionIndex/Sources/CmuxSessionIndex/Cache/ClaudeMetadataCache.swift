public import Foundation

/// Cache for parsed Claude session metadata, keyed by file URL with mtime as
/// the freshness check. Avoids re-reading and re-parsing the same jsonls across
/// pagination calls. Bounded by `maxEntries` to keep memory in check (LRU on
/// insert). Owned by a single `SessionIndexStore` and injected into the
/// nonisolated static loader chain (no process-wide singleton).
///
/// Isolation: an `actor` rather than a lock-guarded class. The only mutators
/// and readers are the per-file `group.addTask` closures inside
/// `loadClaudeEntries`, which are already `async`, so `get`/`put` are `async`
/// and the actor serializes access without an `NSLock` or `@unchecked Sendable`
/// escape hatch. LRU semantics (`maxEntries`, ~10% oldest-mtime eviction,
/// mtime-freshness) are unchanged from the prior lock-guarded form.
public actor ClaudeMetadataCache {
    private let maxEntries = 1000
    private var entries: [URL: (mtime: Date, entry: SessionEntry)] = [:]

    /// Creates an empty cache. One instance is owned per `SessionIndexStore`.
    public init() {}

    /// Returns the cached entry for `url` only when its stored mtime matches
    /// `mtime`; a stale or missing entry returns `nil`.
    public func get(url: URL, mtime: Date) -> SessionEntry? {
        guard let cached = entries[url], cached.mtime == mtime else { return nil }
        return cached.entry
    }

    /// Stores `entry` for `url` at `mtime`, evicting ~10% of the oldest-mtime
    /// entries once the cache exceeds `maxEntries`.
    public func put(url: URL, mtime: Date, entry: SessionEntry) {
        entries[url] = (mtime, entry)
        if entries.count > maxEntries {
            // Evict ~10% (oldest mtimes) to amortize cleanup cost.
            let evictCount = entries.count / 10
            let oldestKeys = entries
                .sorted { $0.value.mtime < $1.value.mtime }
                .prefix(evictCount)
                .map(\.key)
            for k in oldestKeys { entries.removeValue(forKey: k) }
        }
    }
}
