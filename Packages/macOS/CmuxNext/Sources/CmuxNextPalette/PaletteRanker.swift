public import Foundation
import os

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
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "palette.ranker")

    private let bridge: PaletteRankerBridge?
    /// Why the shared ranker did not load (its bundle is missing or broken), nil when it did.
    /// Without it every page ranks to no rows, so the reason is kept and logged instead of lost.
    nonisolated public let loadError: PaletteRankerBridgeError?

    /// Creates a ranker with a persistent JavaScriptCore context.
    nonisolated public convenience init() {
        self.init(loading: { try PaletteRankerBridge() })
    }

    nonisolated init(loading: () throws -> PaletteRankerBridge) {
        do {
            bridge = try loading()
            loadError = nil
        } catch {
            let reason = error as? PaletteRankerBridgeError ?? .runtimeFailed(String(describing: error))
            bridge = nil
            loadError = reason
            Self.logger.fault("palette ranker did not load, the palette has no rows: \(reason.localizedDescription, privacy: .public)")
        }
    }

    /// Ranks a prepared palette index through the shared TypeScript engine.
    ///
    /// - Parameter version: A stable snapshot identifier. Reusing it for the
    ///   same entries lets the bridge reuse its prepared text fields.
    nonisolated public func rank(
        index: inout PaletteSearchIndex,
        version: Int? = nil,
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
            guard let bridge else { return [] }
            return try bridge.rank(
                index: index,
                version: version,
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
            return []
        }
    }

    /// Ranks the visible rows for an empty query through the shared TypeScript engine.
    nonisolated public func rankEmpty(
        entries: [PaletteSearchEntry],
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5
    ) -> [PaletteRankedSection] {
        do {
            guard let bridge else { return [] }
            return try bridge.rankEmpty(
                entries: entries,
                sectionOrders: sectionOrders,
                frecency: frecency,
                now: now,
                showsRecent: showsRecent,
                recentLimit: recentLimit
            )
        } catch {
            return []
        }
    }
}
