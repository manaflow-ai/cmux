import Foundation

nonisolated struct PaletteRankerBridgeRequest: Encodable {
    /// What the ranker does (cmux-palette-ranker's `request.operation`): a typed query, or the
    /// empty query's sections. An in-process FFI call, not a daemon operation.
    nonisolated enum Operation: String, Encodable {
        case rank
        case rankEmpty
    }

    let operation: Operation
    /// Nil when the context already holds this `version`'s entries (installed once per version).
    let entries: [PaletteRankerBridgeEntry]?
    let version: Int?
    let query: String?
    let sectionOrders: [Int]
    let frecency: PaletteRankerBridgeFrecency
    let now: Double
    let showsRecent: Bool
    let keepsSectionOrder: Bool
    let ranksPrefixFirst: Bool
    let recentLimit: Int
    /// The user's aliases and pins (`PaletteRankSettings`); nil when there are none.
    let aliases: [String: [String]]?
    let pins: [String]?
    let pinnedSectionIndex: Int?
    let rowLimit: Int
    let highlightLimit: Int
}
