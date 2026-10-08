public import Foundation

/// Runs searches off the main actor on the latest index snapshot. Each
/// request carries a generation; the caller drops results whose generation
/// is stale, so fast typing never shows an older query's rows.
public actor PaletteSearcher {
    private var index = PaletteSearchIndex(entries: [])
    private var indexVersion = -1
    private let bridge: PaletteRankerBridge?

    public init() {
        bridge = try? PaletteRankerBridge()
    }

    /// Installs a new snapshot unless this version is already current.
    public func install(_ snapshot: PaletteSearchIndex, version: Int) {
        guard version != indexVersion else { return }
        index = snapshot
        indexVersion = version
    }

    /// Builds the index here, off the main actor, when `version` is new.
    public func install(entries: [PaletteSearchEntry], version: Int) {
        guard version != indexVersion else { return }
        index = PaletteSearchIndex(entries: entries)
        indexVersion = version
    }

    /// Installs `entries` (when `version` is new) and ranks `query` on them in one actor turn
    /// (state-audit P2): no other caller's install can land between the two, so the search ranks
    /// its own page. A cancelled caller (a search the next keystroke superseded) ranks nothing.
    public func search(
        entries: [PaletteSearchEntry],
        version: Int,
        query: String,
        generation: Int,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false
    ) -> (generation: Int, sections: [PaletteRankedSection]) {
        if Task.isCancelled { return (generation, []) }
        install(entries: entries, version: version)
        return search(query: query, generation: generation, sectionOrders: sectionOrders, frecency: frecency, now: now,
                      showsRecent: showsRecent, keepsSectionOrder: keepsSectionOrder, ranksPrefixFirst: ranksPrefixFirst)
    }

    public func search(
        query: String,
        generation: Int,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false
    ) -> (generation: Int, sections: [PaletteRankedSection]) {
        let sections: [PaletteRankedSection]
        do {
            guard let bridge else { return (generation, []) }
            sections = try bridge.rank(
                index: index,
                version: indexVersion,
                query: query,
                sectionOrders: sectionOrders,
                frecency: frecency,
                now: now,
                showsRecent: showsRecent,
                keepsSectionOrder: keepsSectionOrder,
                ranksPrefixFirst: ranksPrefixFirst
            )
        } catch {
            return (generation, [])
        }
        return (generation, sections)
    }
}
