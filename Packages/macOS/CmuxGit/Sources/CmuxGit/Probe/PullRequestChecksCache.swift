import Foundation

/// Bounded optional-check cache. Keys include credential identity and head SHA.
actor PullRequestChecksCache {
    private var entries: [String: PullRequestChecksCacheEntry] = [:]
    private let lifetime: TimeInterval = 30
    private let maximumEntries = 256

    /// Captures the current request generation; pending and completed entries share one bound.
    func begin(for key: String, now: Date, allowCachedResults: Bool) -> PullRequestChecksCacheEntry {
        entries = entries.filter { now.timeIntervalSince($0.value.fetchedAt) < lifetime }
        if var entry = entries[key] {
            if !allowCachedResults {
                entry.summary = nil
                entries[key] = entry
            }
            return entry
        }
        if entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let entry = PullRequestChecksCacheEntry(generation: UUID(), fetchedAt: now, summary: nil)
        entries[key] = entry
        return entry
    }

    /// Removing a generation also rejects publication by every older in-flight request.
    func invalidate(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// Atomically validates the generation before publishing or caching a result.
    func accept(
        _ summary: PullRequestChecksSummary,
        for key: String,
        generation: UUID,
        now: Date,
        cacheable: Bool
    ) -> Bool {
        guard var entry = entries[key], entry.generation == generation else { return false }
        entry.summary = cacheable ? summary : nil
        entry.fetchedAt = now
        entries[key] = entry
        return true
    }
}
