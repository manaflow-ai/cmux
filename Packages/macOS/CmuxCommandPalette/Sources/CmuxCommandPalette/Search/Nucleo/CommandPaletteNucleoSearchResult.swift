import Foundation

/// One scored hit returned by ``CommandPaletteNucleoSearchIndex``.
public struct CommandPaletteNucleoSearchResult<Payload>: Sendable where Payload: Sendable {
    /// The matched entry's payload.
    public let payload: Payload
    /// The matched entry's rank.
    public let rank: Int
    /// The matched entry's title.
    public let title: String
    /// Rounded, clamped nucleo score including any boost.
    public let score: Int
    /// Title character indices to highlight (computed by the Swift matcher).
    public let titleMatchIndices: Set<Int>
}
