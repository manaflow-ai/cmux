public import Foundation

/// One ranked row by entry index. Sendable; the main actor maps it to an item.
nonisolated public struct PaletteRankedRow: Sendable, Hashable {
    public let index: Int
    public let score: Int
    /// Scalar offsets into the entry title that matched.
    public let highlights: [Int]
}

/// A group of ranked rows. `sectionIndex` nil is the Recent section.
nonisolated public struct PaletteRankedSection: Sendable, Hashable {
    public let sectionIndex: Int?
    public let rows: [PaletteRankedRow]
}

/// Thin Swift compatibility surface for the shared TypeScript ranker.
///
/// The palette keeps this API so existing providers and callers do not need to
/// know about JavaScriptCore. All scoring, matching, frecency and grouping now
/// run in `webviews/src/palette/ranker.ts` through one persistent
/// ``PaletteRankerBridge``.
public final class PaletteRanker {
    private let bridge: PaletteRankerBridge

    /// Creates a ranker with a persistent JavaScriptCore context.
    public init() {
        do {
            bridge = try PaletteRankerBridge()
        } catch {
            preconditionFailure("Palette ranker bridge unavailable: \(error.localizedDescription)")
        }
    }

    /// Ranks a prepared palette index through the shared TypeScript engine.
    public func rank(
        index: inout PaletteSearchIndex,
        query: String,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false,
        recentLimit: Int = 5,
        rowLimit: Int = 400,
        highlightLimit: Int = 60
    ) -> [PaletteRankedSection] {
        do {
            return try bridge.rank(
                index: index,
                query: query,
                sectionOrders: sectionOrders,
                frecency: frecency,
                now: now,
                showsRecent: showsRecent,
                keepsSectionOrder: keepsSectionOrder,
                ranksPrefixFirst: ranksPrefixFirst,
                recentLimit: recentLimit,
                rowLimit: rowLimit,
                highlightLimit: highlightLimit
            )
        } catch {
            preconditionFailure("Palette rank failed: \(error.localizedDescription)")
        }
    }

    /// Ranks the visible rows for an empty query through the shared TypeScript engine.
    public func rankEmpty(
        entries: [PaletteSearchEntry],
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5
    ) -> [PaletteRankedSection] {
        do {
            return try bridge.rankEmpty(
                entries: entries,
                sectionOrders: sectionOrders,
                frecency: frecency,
                now: now,
                showsRecent: showsRecent,
                recentLimit: recentLimit
            )
        } catch {
            preconditionFailure("Palette empty-query rank failed: \(error.localizedDescription)")
        }
    }
}
