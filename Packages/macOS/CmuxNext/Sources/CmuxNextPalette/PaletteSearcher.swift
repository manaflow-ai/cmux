public import Foundation
import os

/// Runs searches off the main actor on the latest index snapshot. Each
/// request carries a generation; the caller drops results whose generation
/// is stale, so fast typing never shows an older query's rows.
public actor PaletteSearcher {
    private var index = PaletteSearchIndex(entries: [])
    private var indexVersion = -1
    private let bridge: PaletteRankerBridge?
    /// Tests: runs on the actor as each call returns, the moment another caller of the shared
    /// searcher would get it next (state-audit P2), so a test interleaves deterministically.
    private var betweenCalls: (@Sendable (isolated PaletteSearcher) -> Void)?

    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.searcher")
    /// Why the shared ranker did not load here (its bundle is missing or broken), nil when it
    /// did. Without it every query ranks to no rows, so the reason is kept and logged, not lost.
    public nonisolated let loadError: PaletteRankerBridgeError?

    public init() {
        self.init(loading: { try PaletteRankerBridge() })
    }

    init(loading: @Sendable () throws -> PaletteRankerBridge) {
        do {
            bridge = try loading()
            loadError = nil
        } catch {
            let reason = error as? PaletteRankerBridgeError ?? .runtimeFailed(String(describing: error))
            bridge = nil
            loadError = reason
            Self.logger.fault("palette searcher ranker did not load, searches have no rows: \(reason.localizedDescription, privacy: .public)")
        }
    }

    /// Tests: sets ``betweenCalls``.
    func setBetweenCalls(_ hook: (@Sendable (isolated PaletteSearcher) -> Void)?) {
        betweenCalls = hook
    }

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
        apply(entries: entries, version: version)
    }

    private func apply(entries: [PaletteSearchEntry], version: Int) {
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
        defer { endCall() }
        if Task.isCancelled { return (generation, []) }
        apply(entries: entries, version: version)
        return rank(query: query, generation: generation, sectionOrders: sectionOrders, frecency: frecency, now: now,
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
        defer { endCall() }
        return rank(query: query, generation: generation, sectionOrders: sectionOrders, frecency: frecency, now: now,
                    showsRecent: showsRecent, keepsSectionOrder: keepsSectionOrder, ranksPrefixFirst: ranksPrefixFirst)
    }

    private func rank(
        query: String,
        generation: Int,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool,
        ranksPrefixFirst: Bool
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
