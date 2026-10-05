import Foundation

nonisolated struct PaletteRankerBridgeRequest: Encodable {
    let operation: String
    let entries: [PaletteRankerBridgeEntry]
    let version: Int?
    let query: String?
    let sectionOrders: [Int]
    let frecency: PaletteRankerBridgeFrecency
    let now: Double
    let showsRecent: Bool
    let keepsSectionOrder: Bool
    let ranksPrefixFirst: Bool
    let recentLimit: Int
    let rowLimit: Int
    let highlightLimit: Int
}

