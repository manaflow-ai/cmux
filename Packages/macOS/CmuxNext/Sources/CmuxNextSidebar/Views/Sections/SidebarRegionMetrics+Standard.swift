import CmuxNextDesign
import CoreGraphics

extension SidebarRegionMetrics {
    /// From the design tokens, read at layout time so density applies live.
    @MainActor static var standard: SidebarRegionMetrics {
        SidebarRegionMetrics(
            rowHeight: Metrics.sidebarRowHeight, headerHeight: Metrics.sidebarHeaderHeight,
            inset: SidebarStyle.horizontalInset, sectionGap: Metrics.space2, padding: Metrics.space1,
            cardPadding: Metrics.space1, tileMinWidth: Metrics.sidebarRowHeight * 1.5,
            tileHeight: Metrics.sidebarRowHeight + Metrics.space2, tileGap: Metrics.space2,
            iconButtonWidth: Metrics.sidebarRowHeight + Metrics.space2, lineWidth: Metrics.dividerThickness)
    }

    /// Share of the sidebar height the band above the list may take
    /// before it scrolls inside.
    static let aboveShare: CGFloat = 1.0 / 3.0
    /// Share for the band below the list.
    static let belowShare: CGFloat = 1.0 / 4.0
}
