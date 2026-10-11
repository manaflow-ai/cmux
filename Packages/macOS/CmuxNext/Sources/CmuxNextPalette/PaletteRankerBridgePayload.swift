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
    let typingSectionIndex: Int?
    let actionID: String?
    let demoted: Bool
    let hasShortcut: Bool
    let suggestedRank: Int?
    let suggestedSectionIndex: Int?
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
        typingSectionIndex = entry.typingSectionIndex
        actionID = entry.actionID
        demoted = entry.demoted
        hasShortcut = entry.hasShortcut
        suggestedRank = entry.suggestedRank
        suggestedSectionIndex = entry.suggestedSectionIndex
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
    let picks: [PaletteRankerBridgePick]
    let pickHalfLife: Double
    let hidden: [String]

    /// `query` nil sends no learned picks (the empty query); otherwise only the
    /// picks whose start begins the query go (the ranker reads no others), so
    /// a keystroke never carries the whole history.
    init(_ store: FrecencyStore, query: String? = nil) {
        entries = store.entries.mapValues { entry in
            PaletteRankerBridgeFrecencyEntry(score: entry.score, lastUsed: entry.lastUsed.timeIntervalSinceReferenceDate)
        }
        halfLife = store.halfLife
        capacity = store.capacity
        let normalized = query.map(Self.normalized) ?? ""
        picks = store.picks.filter { !normalized.isEmpty && normalized.hasPrefix($0.prefix) }.map { pick in
            PaletteRankerBridgePick(prefix: pick.prefix, key: pick.key, score: pick.score,
                                    lastUsed: pick.lastUsed.timeIntervalSinceReferenceDate, last: pick.isLast)
        }
        pickHalfLife = store.pickHalfLife
        hidden = store.hidden.sorted()
    }

    /// The query as learned picks key it (the daemon's rule, palette_usage.rs
    /// `normalized_query`): white space collapsed, lowercased.
    static func normalized(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
