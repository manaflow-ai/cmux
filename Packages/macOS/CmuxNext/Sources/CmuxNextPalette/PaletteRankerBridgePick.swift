import Foundation

/// One learned pick as the shared ranker reads it (`LearnedPick` in
/// cmux-tui/crates/cmux-palette-ranker).
nonisolated struct PaletteRankerBridgePick: Encodable {
    let prefix: String
    let key: String
    let score: Double
    let lastUsed: Double
    let last: Bool
}
