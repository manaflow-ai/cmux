import Foundation

nonisolated struct PaletteRankerBridgeEntry: Encodable {
    let title: String
    let keywords: [String]
    let subtitle: String?
    let accessory: String?
    let rankBias: Int
    let frecencyKey: String?
    let isEnabled: Bool
    let isVisibleWhenQueryEmpty: Bool
    let queryPrefix: String?
    let hidesWhenTyping: Bool
    let sectionIndex: Int
    let entersScope: Bool

    init(_ entry: PaletteSearchEntry) {
        title = entry.title
        keywords = entry.keywords
        subtitle = entry.subtitle
        accessory = entry.accessory
        rankBias = entry.rankBias
        frecencyKey = entry.frecencyKey
        isEnabled = entry.isEnabled
        isVisibleWhenQueryEmpty = entry.isVisibleWhenQueryEmpty
        queryPrefix = entry.queryPrefix
        hidesWhenTyping = entry.hidesWhenTyping
        sectionIndex = entry.sectionIndex
        entersScope = entry.entersScope
    }
}

nonisolated struct PaletteRankerBridgeFrecencyEntry: Encodable {
    let score: Double
    let lastUsed: Double
}

nonisolated struct PaletteRankerBridgeFrecency: Encodable {
    let entries: [String: PaletteRankerBridgeFrecencyEntry]
    let halfLife: Double
    let capacity: Int

    init(_ store: FrecencyStore) {
        entries = store.entries.mapValues { entry in
            PaletteRankerBridgeFrecencyEntry(score: entry.score, lastUsed: entry.lastUsed.timeIntervalSinceReferenceDate)
        }
        halfLife = store.halfLife
        capacity = store.capacity
    }
}
