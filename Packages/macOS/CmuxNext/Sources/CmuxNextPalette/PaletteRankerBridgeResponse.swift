import Foundation

nonisolated struct PaletteRankerBridgeRow: Decodable {
    let index: Int
    let score: Int
    let highlights: [Int]
}

nonisolated struct PaletteRankerBridgeSection: Decodable {
    let sectionIndex: Int?
    let rows: [PaletteRankerBridgeRow]
}

