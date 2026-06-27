/// Bounded LRU cache of merged per-directory `DirectorySnapshot`s held by
/// `SessionIndexStore`. Backs the Show-more popover's empty-query scroll path:
/// the popover slices a cached snapshot in memory instead of asking the store
/// for more pages on every scroll, eliminating the O(n²) repeated
/// refetch-and-merge behavior.
///
/// `@MainActor` because every mutator and reader runs on the store's main-actor
/// isolation domain; the state is internal bookkeeping that was never an
/// observation source, so this is a plain reference type the store holds rather
/// than an `@Observable` model.
@MainActor
final class DirectorySnapshotCache {
    private var cache: [String: DirectorySnapshot] = [:]
    private var lru: [String] = []

    /// Bumped on every store `reload()`. Snapshot builds capture this at start;
    /// if it changes before the build completes (reload raced with an
    /// in-flight build), the build's result is discarded instead of being
    /// written back into the cache — otherwise the stale pre-reload result
    /// would repopulate the cache after invalidation and be reused on the next
    /// popover open.
    private(set) var generation: Int = 0

    private let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
    }

    func bumpGeneration() {
        generation += 1
    }

    /// Return the cached snapshot for `key`, refreshing its LRU recency. Nil on miss.
    func cached(_ key: String) -> DirectorySnapshot? {
        guard let cached = cache[key] else { return nil }
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
        return cached
    }

    /// Insert `snapshot` for `key`, evicting the least-recently-used entry when
    /// inserting a new key would exceed capacity.
    func store(key: String, snapshot: DirectorySnapshot) {
        if cache[key] == nil,
           cache.count >= capacity,
           let oldestKey = lru.first {
            cache.removeValue(forKey: oldestKey)
            lru.removeFirst()
        }
        cache[key] = snapshot
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
    }

    func invalidate() {
        cache.removeAll()
        lru.removeAll()
    }
}
