import CoreGraphics

/// The detail container's top edge, measured outside the owned bar's inset.
struct WorkspaceOwnedBarContainerTop: Equatable {
    /// The window y-coordinate where the container's safe area begins, which
    /// is where the owned bar sits before any placement adjustment.
    let barTop: CGFloat
    /// The container's top safe-area inset.
    let topInset: CGFloat
    /// The container's reported top-trailing corner inset.
    let topTrailingCorner: CGSize

    static let zero = WorkspaceOwnedBarContainerTop(barTop: 0, topInset: 0, topTrailingCorner: .zero)
}

/// Where the workspace detail bar sits on a phone split layout.
///
/// With the sidebar hidden, the bar can rise into a status band whose system
/// content occupies only the trailing corner (the unfolded iPhone Duo in
/// portrait reports an 82 pt top inset while the time and connection
/// indicators sit in its top-trailing corner); the bar keeps its trailing
/// controls clear of that corner. With the sidebar shown, the bar lines up
/// with the sidebar's system toolbar row and matches its control height.
/// Any other shape leaves the bar below the safe area.
struct WorkspaceOwnedBarStatusBand: Equatable {
    /// How far the bar rises from its safe-area position; negative lowers it.
    let raise: CGFloat
    /// Extra trailing room that keeps the bar clear of the corner content.
    let trailingClearance: CGFloat
    /// Extra height above and below each control, matching the system
    /// toolbar's glass group (a 44 pt control draws a 48 pt group).
    var controlOutset: CGFloat = 0

    static let none = WorkspaceOwnedBarStatusBand(raise: 0, trailingClearance: 0)

    /// The system toolbar's glass group rim around a 44 pt control.
    static let sidebarRowControlOutset: CGFloat = 2

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

    /// Centers the bar on the sidebar's toolbar row.
    /// - Parameters:
    ///   - rowFrame: The sidebar toolbar toggle's window frame.
    ///   - container: The detail container's top edge.
    ///   - barHeight: The bar's full height with the outset controls.
    /// - Returns: The aligned placement, or `nil` when lining up would move the
    ///   bar into the container's top safe area.
    static func aligned(
        withSidebarRow rowFrame: CGRect,
        container: WorkspaceOwnedBarContainerTop,
        barHeight: CGFloat
    ) -> WorkspaceOwnedBarStatusBand? {
        let alignedTop = rowFrame.midY - barHeight / 2
        // Portrait's sidebar row sits in the status band, where the detail's
        // trailing controls would meet the corner content.
        guard rowFrame.height > 0, alignedTop >= container.barTop - 1 else {
            return nil
        }
        return WorkspaceOwnedBarStatusBand(
            raise: container.barTop - alignedTop,
            trailingClearance: 0,
            controlOutset: sidebarRowControlOutset
        )
    }
}
