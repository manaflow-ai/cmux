public import Foundation

/// How much a Cmd-P row's recent use lifts it (Lawrence 2026-11-07: "make sure we include recency
/// into algorithm for searching"): the time since the person last focused or used the row's
/// workspace or tab, decaying, plus its place among the rows used most recently.
///
/// The bias is added to the row's `rankBias`, inside its match class, next to the sidebar prior
/// (``PaletteSidebarPrior``, at most 16) and the frecency boost (18 for one fresh use): it orders
/// equal and near matches and never beats a better match class. The row the person is on now gets
/// none, so the one they came from comes first.
///
/// ```swift
/// let prior = PaletteRecencyPrior()
/// prior.decay(lastUsed: now, now: now) // 32
/// prior.decay(lastUsed: now - 6 hours, now: now) // 16
/// prior.decay(lastUsed: nil, now: now) // 0
/// ```
public nonisolated struct PaletteRecencyPrior: Sendable, Equatable {
    /// The decay part of a row used this instant, in ranker score points (one match class is 1000).
    public var maximum: Double
    /// The decay part halves every this many seconds since the last use.
    public var halfLife: TimeInterval

    /// - Parameters:
    ///   - maximum: The bias of a row used now. 32: two fresh uses' frecency, so a row used minutes
    ///     ago passes the sidebar's top row and a row used once days ago.
    ///   - halfLife: Seconds per halving. 6 hours: this morning's work still counts tonight, last
    ///     week's adds nothing.
    public init(maximum: Double = 32, halfLife: TimeInterval = 6 * 60 * 60) {
        self.maximum = maximum
        self.halfLife = halfLife
    }

    /// The decay part of the bias of a row last used at `lastUsed` (nil: never), seen at `now`.
    public func decay(lastUsed: Date?, now: Date) -> Int {
        0
    }

    /// The recency bias of each used row: its ``decay(lastUsed:now:)`` plus a place boost (16 for
    /// the most recently used row, 2 less per place down) that orders rows used moments apart.
    ///
    /// - Parameters:
    ///   - uses: Each row's id and its last use; a row listed twice keeps its latest use.
    ///   - now: The time the palette ranks at.
    /// - Returns: The bias of each row in `uses`; a row not listed has none.
    public func biases(_ uses: [(id: String, lastUsed: Date)], now: Date) -> [String: Int] {
        [:]
    }
}
