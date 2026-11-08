import CoreGraphics

/// Where the workspace detail bar can sit when the top safe area is a status
/// band whose system content occupies only the trailing corner (the unfolded
/// iPhone Duo in portrait reports an 82 pt top inset while the time and
/// connection indicators sit in its top-trailing corner). The bar rises into
/// the band and keeps its trailing controls clear of that corner. Any other
/// shape leaves the bar below the safe area.
struct WorkspaceOwnedBarStatusBand: Equatable {
    /// How far the bar rises into the top safe area.
    let raise: CGFloat
    /// Extra trailing room that keeps the bar clear of the corner content.
    let trailingClearance: CGFloat

    static let none = WorkspaceOwnedBarStatusBand(raise: 0, trailingClearance: 0)

    /// - Parameters:
    ///   - topInset: The container's top safe-area inset.
    ///   - topTrailingCorner: The container's reported top-trailing corner inset.
    ///   - barHeight: The bar's full height, including its vertical padding.
    /// - Returns: The bar placement, or ``none`` when the band can't hold the bar.
    static func placement(
        topInset: CGFloat,
        topTrailingCorner: CGSize,
        barHeight: CGFloat
    ) -> WorkspaceOwnedBarStatusBand {
        // The corner must account for the whole band; otherwise something
        // other than the trailing status content owns the top edge.
        guard topInset >= barHeight,
              topTrailingCorner.width > 0,
              topTrailingCorner.height >= topInset - 1 else {
            return .none
        }
        return WorkspaceOwnedBarStatusBand(
            raise: barHeight,
            trailingClearance: topTrailingCorner.width
        )
    }
}
