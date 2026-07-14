/// Preview surfaces demanded by the currently visible pane tab-strip cards.
public struct PaneTabStripPreviewDemand: Equatable, Sendable {
    /// Surface identifiers for cards intersecting the strip viewport.
    public let surfaceIDs: Set<String>

    /// Derives demand from immutable cards and visible surface identifiers.
    /// - Parameters:
    ///   - cards: Cards in the current strip projection.
    ///   - visibleCardIDs: Card identifiers currently intersecting the viewport.
    public init(cards: [PaneTabStripCardSnapshot], visibleCardIDs: Set<String>) {
        surfaceIDs = Set(cards.lazy.map(\.id).filter(visibleCardIDs.contains))
    }
}
