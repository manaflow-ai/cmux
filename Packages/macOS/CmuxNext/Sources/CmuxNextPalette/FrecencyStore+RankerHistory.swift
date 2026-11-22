public import Foundation

extension FrecencyStore {
    /// ``rankerHistory(keyPrefix:query:now:)`` built and encoded off the main thread (it maps and
    /// JSON-encodes up to the store's capacity of entries, too much for a key's turn).
    public func encodedRankerHistory(keyPrefix: String, query: String, now: Date) async -> String? {
        let store = self
        return await Task.detached(priority: .userInitiated) {
            store.rankerHistory(keyPrefix: keyPrefix, query: query, now: now)
        }.value
    }

    /// This history as the shared ranker reads it (`{now, frecency}` JSON text), for a list that a
    /// daemon ranks with the same ranker (acpmux's chats window): only the entries and hidden keys
    /// under `keyPrefix`, and only the learned picks that begin `query`, so the text stays small.
    /// The same payload the palette's own ranker gets for those rows, so the order is the same.
    public nonisolated func rankerHistory(keyPrefix: String, query: String, now: Date) -> String? {
        let all = PaletteRankerBridgeFrecency(self, query: query)
        let mine = PaletteRankerBridgeFrecency(entries: all.entries.filter { $0.key.hasPrefix(keyPrefix) },
                                               halfLife: all.halfLife, capacity: all.capacity,
                                               picks: all.picks.filter { $0.key.hasPrefix(keyPrefix) },
                                               pickHalfLife: all.pickHalfLife,
                                               hidden: all.hidden.filter { $0.hasPrefix(keyPrefix) })
        nonisolated struct Payload: Encodable {
            let now: Double
            let frecency: PaletteRankerBridgeFrecency
        }
        guard let data = try? JSONEncoder().encode(Payload(now: now.timeIntervalSinceReferenceDate, frecency: mine)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension PaletteModel {
    /// The palette's choice history of the rows under `keyPrefix` for `query`, as the shared ranker reads it,
    /// encoded off the main thread (``FrecencyStore/encodedRankerHistory(keyPrefix:query:now:)``).
    public func rankerHistory(keyPrefix: String, query: String) async -> String? {
        await frecency.encodedRankerHistory(keyPrefix: keyPrefix, query: query, now: now())
    }
}
