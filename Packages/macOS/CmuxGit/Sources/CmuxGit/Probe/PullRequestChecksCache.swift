import Foundation

/// Bounded optional-check cache. Keys include credential identity and head SHA.
actor PullRequestChecksCache {


    private var entries: [String: PullRequestChecksCacheEntry] = [:]
    private var invalidatedKeys: Set<String> = []
    private let lifetime: TimeInterval = 30
    private let maximumEntries = 256

    func value(for key: String, now: Date) -> PullRequestChecksSummary? {
        guard !invalidatedKeys.contains(key),
              let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.summary
    }

    func invalidate(_ key: String) {
        entries.removeValue(forKey: key)
        invalidatedKeys.insert(key)
    }

    func insert(_ summary: PullRequestChecksSummary, for key: String, now: Date) {
        invalidatedKeys.remove(key)
        entries = entries.filter { now.timeIntervalSince($0.value.fetchedAt) < lifetime }
        if entries[key] == nil, entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = PullRequestChecksCacheEntry(fetchedAt: now, summary: summary)
    }
}
