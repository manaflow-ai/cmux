import Foundation

/// Completed origins only; access order is independent of expiry, and temporary failures never enter.
nonisolated struct AgentPaneSourceIconCache {
    private struct Entry {
        let result: AgentPaneSourceIconResult
        let expires: Duration
        var access: UInt64
    }
    let capacity: Int
    private var entries: [URL: Entry] = [:]
    private var access: UInt64 = 0

    init(capacity: Int) { self.capacity = max(0, capacity) }

    mutating func result(at origin: URL, now: Duration) -> AgentPaneSourceIconResult? {
        guard var entry = entries[origin] else { return nil }
        guard entry.expires > now else { entries[origin] = nil; return nil }
        access += 1
        entry.access = access
        entries[origin] = entry
        return entry.result
    }

    mutating func insert(_ result: AgentPaneSourceIconResult, at origin: URL, now: Duration) {
        guard capacity > 0, result != .temporary else { return }
        entries = entries.filter { $0.value.expires > now }
        access += 1
        let ttl: Duration = result.png == nil ? .seconds(10 * 60) : .seconds(6 * 60 * 60)
        entries[origin] = Entry(result: result, expires: now + ttl, access: access)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries[oldest] = nil
        }
    }
}
