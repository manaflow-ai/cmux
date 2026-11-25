public import Foundation

/// How much a Go to Workspace row's place in the sidebar lifts it: the top row most, halving every
/// ``halfRank`` rows down (Lawrence 2026-11-05: "account for how far up the sidebar something is").
///
/// The bias is added to the row's `rankBias`, inside its match class, so it orders equal or near
/// matches and never beats a better match. It stays below one fresh use's frecency boost (18), so
/// history outranks place, and a learned pick for the typed query start lifts over both.
///
/// ```swift
/// let prior = PaletteSidebarPrior()
/// prior.bias(rank: 0) // 16, the sidebar's top row
/// prior.bias(rank: 6) // 8
/// prior.bias(rank: nil) // 0, a row the sidebar does not draw
/// ```
public nonisolated struct PaletteSidebarPrior: Sendable, Equatable {
    /// The bias of the sidebar's top row, in ranker score points (one match class is 1000).
    public var maximum: Double
    /// The bias halves every this many rows down the sidebar.
    public var halfRank: Double

    /// - Parameters:
    ///   - maximum: The top row's bias. 16 keeps it below one use's frecency boost (18).
    ///   - halfRank: Rows per halving. 6: the first screen of rows tells apart, row 30 adds 1 at most.
    public init(maximum: Double = 16, halfRank: Double = 6) {
        self.maximum = maximum
        self.halfRank = halfRank
    }

    /// The bias of the row at sidebar place `rank` (0 is the top), 0 for nil.
    public func bias(rank: Int?) -> Int {
        guard let rank, rank >= 0, halfRank > 0 else { return 0 }
        return Int((maximum * exp2(-Double(rank) / halfRank)).rounded())
    }
}
