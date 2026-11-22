import Foundation

/// One learned pick as the shared ranker reads it (`PaletteLearnedPick` in
/// webviews/src/palette/ranker.ts).
nonisolated struct PaletteRankerBridgePick: Encodable {
    let prefix: String
    let key: String
    let score: Double
    let lastUsed: Double
    let last: Bool
}
