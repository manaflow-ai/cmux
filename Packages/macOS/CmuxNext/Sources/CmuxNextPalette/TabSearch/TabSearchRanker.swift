public import Foundation

/// One ranked Search Tabs result.
public nonisolated struct TabSearchMatch: Sendable, Hashable {
    public var row: TabSearchRow
    /// The fuzzy match score (0 for an empty query).
    public var score: Int
}

/// Ranks Search Tabs rows for a query exactly as the palette page does
/// (same rows, same fuzzy index, same section order), for callers without
/// a palette: the `tab.search` control method behind `cmux tab search` and
/// the MCP tool. Pure.
public nonisolated enum TabSearchRanker {
    public static func search(_ entries: [TabSearchEntry], query: String, style: TabSearchStyle = .recent,
                              includeClosed: Bool = true, limit: Int = 50, now: Date) -> [TabSearchMatch] {
        var rows = TabSearchPlan.rows(entries, style: style, now: now)
        if !includeClosed { rows.removeAll { $0.entry.isClosed } }
        var sectionIndex: [String: Int] = [:]
        var sectionOrders: [Int] = []
        let searchEntries = rows.map { row in
            let index = sectionIndex[row.section.id] ?? {
                let next = sectionOrders.count
                sectionIndex[row.section.id] = next
                sectionOrders.append(row.section.order)
                return next
            }()
            return PaletteSearchEntry(title: row.title, keywords: row.keywords, subtitle: row.subtitle, accessory: row.accessory,
                                      rankBias: row.rankBias, frecencyKey: nil, isEnabled: row.entry.isAvailable,
                                      isVisibleWhenQueryEmpty: row.isVisibleWhenQueryEmpty, sectionIndex: index)
        }
        var index = PaletteSearchIndex(entries: searchEntries)
        let ranked = PaletteRanker.rank(index: &index, query: query, sectionOrders: sectionOrders, frecency: FrecencyStore(),
                                        now: now, showsRecent: false, keepsSectionOrder: true)
        return ranked.flatMap(\.rows).prefix(max(0, limit)).map { TabSearchMatch(row: rows[$0.index], score: $0.score) }
    }
}
