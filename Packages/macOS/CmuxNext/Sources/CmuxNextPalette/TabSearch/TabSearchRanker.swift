public import Foundation
import Synchronization

/// One ranked Search Tabs result.
public nonisolated struct TabSearchMatch: Sendable, Hashable {
    public var row: TabSearchRow
    /// The fuzzy match score (0 for an empty query).
    public var score: Int
}

/// Ranks Search Tabs rows for a query exactly as the palette page does
/// (same rows, same fuzzy index, same section order), for callers without
/// a palette: the `tab.search` control method behind `cmux tab search` and
/// the MCP tool. A ranker instance serializes access to its shared bridge.
// crash-allow: the ranker owns a Mutex around its non-Sendable JavaScriptCore bridge.
public final class TabSearchRanker: @unchecked Sendable {
    nonisolated private let ranker: PaletteRanker
    private struct State {
        var cachedEntries: [PaletteSearchEntry] = []
        var cachedSectionOrders: [Int] = []
        var snapshotVersion = 0
    }
    nonisolated private let state = Mutex(State())

    /// Creates a tab-search ranker with a persistent JavaScriptCore context.
    nonisolated public init() {
        ranker = PaletteRanker()
    }

    /// Ranks Search Tabs rows without mutating the supplied entries.
    nonisolated public func search(_ entries: [TabSearchEntry], query: String, style: TabSearchStyle = .recent,
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
        return state.withLock { state in
            if searchEntries != state.cachedEntries || sectionOrders != state.cachedSectionOrders {
                state.cachedEntries = searchEntries
                state.cachedSectionOrders = sectionOrders
                state.snapshotVersion &+= 1
            }
            return searchLocked(searchEntries, rows: rows, query: query, sectionOrders: sectionOrders,
                                limit: limit, now: now, version: state.snapshotVersion)
        }
    }

    nonisolated private func searchLocked(_ searchEntries: [PaletteSearchEntry], rows: [TabSearchRow], query: String,
                                          sectionOrders: [Int], limit: Int, now: Date, version: Int) -> [TabSearchMatch] {
        var index = PaletteSearchIndex(entries: searchEntries)
        let ranked = ranker.rank(index: &index, version: version, query: query, sectionOrders: sectionOrders, frecency: FrecencyStore(),
                                        now: now, showsRecent: false, keepsSectionOrder: true)
        return ranked.flatMap(\.rows).prefix(max(0, limit)).map { TabSearchMatch(row: rows[$0.index], score: $0.score) }
    }
}
