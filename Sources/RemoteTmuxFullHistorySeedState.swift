import Foundation

/// A control connection's bookkeeping for full-history seeds.
struct RemoteTmuxFullHistorySeedState {
    /// The most history bytes one seed keeps; older rows past it are dropped.
    var byteBudget = RemoteTmuxControlConnection.maximumFullHistoryBytes
    /// A painted seed's row counts, handed from the seed's end to its tracked
    /// completion (see ``RemoteTmuxControlConnection/resolveFullHistorySeed(_:painted:)``).
    var painted: [UUID: RemoteTmuxPaintedFullHistory] = [:]
}

/// What a painted full-history seed held.
struct RemoteTmuxPaintedFullHistory: Equatable {
    /// History rows painted above the screen.
    let historyRows: Int
    /// Oldest rows left out to stay within the byte budget.
    let droppedRows: Int
}
