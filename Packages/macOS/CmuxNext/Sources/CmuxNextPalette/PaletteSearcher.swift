public import Foundation

/// Runs searches off the main actor on the latest index snapshot. Each
/// request carries a generation; the caller drops results whose generation
/// is stale, so fast typing never shows an older query's rows.
public actor PaletteSearcher {
    private var index = PaletteSearchIndex(entries: [])
    private var indexVersion = -1
    private let bridge: PaletteRankerBridge?

    private var betweenCalls: (@Sendable (isolated PaletteSearcher) -> Void)?

    public init() {
        bridge = try? PaletteRankerBridge()
    }

    func setBetweenCalls(_ hook: (@Sendable (isolated PaletteSearcher) -> Void)?) { betweenCalls = hook }

    private func endCall() {
        guard let hook = betweenCalls else { return }
        betweenCalls = nil
        hook(self)
    }

    /// Installs a new snapshot unless this version is already current.
    public func install(_ snapshot: PaletteSearchIndex, version: Int) {
        defer { endCall() }
        guard version != indexVersion else { return }
        index = snapshot
        indexVersion = version
    }

    /// Builds the index here, off the main actor, when `version` is new.
    public func install(entries: [PaletteSearchEntry], version: Int) {
        defer { endCall() }
        guard version != indexVersion else { return }
        index = PaletteSearchIndex(entries: entries)
        indexVersion = version
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
        defer { endCall() }
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
