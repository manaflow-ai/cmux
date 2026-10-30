public import Foundation

extension FrecencyStore {
    /// This history as the shared ranker reads it (`{now, frecency}` JSON text), for a list that a
    /// daemon ranks with the same ranker (acpmux's chats window): only the entries and hidden keys
    /// under `keyPrefix`, and only the learned picks that begin `query`, so the text stays small.
    /// The same payload the palette's own ranker gets for those rows, so the order is the same.
    public func rankerHistory(keyPrefix: String, query: String, now: Date) -> String? {
        let all = PaletteRankerBridgeFrecency(self, query: query)
        let mine = PaletteRankerBridgeFrecency(entries: all.entries.filter { $0.key.hasPrefix(keyPrefix) },
                                               halfLife: all.halfLife, capacity: all.capacity,
                                               picks: all.picks.filter { $0.key.hasPrefix(keyPrefix) },
                                               pickHalfLife: all.pickHalfLife,
                                               hidden: all.hidden.filter { $0.hasPrefix(keyPrefix) })
        struct Payload: Encodable {
            let now: Double
            let frecency: PaletteRankerBridgeFrecency
        }
        guard let data = try? JSONEncoder().encode(Payload(now: now.timeIntervalSinceReferenceDate, frecency: mine)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
