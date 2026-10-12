import CmuxNextDesign
import CoreGraphics

extension SidebarRegionMetrics {
    /// From the design tokens, read at layout time so density applies live.
    @MainActor static var standard: SidebarRegionMetrics {
        SidebarRegionMetrics(
            rowHeight: Metrics.sidebarRowHeight, headerHeight: Metrics.sidebarHeaderHeight,
            // Keep the pinned footer clear of the window's rounded lower
            // corner. The same grid step as the row's horizontal breathing
            // room keeps the Settings and account destinations aligned with
            // the top of the sidebar.
            inset: SidebarStyle.horizontalInset, sectionGap: Metrics.space2, padding: Metrics.space2,
            cardPadding: Metrics.space1, tileMinWidth: Metrics.sidebarRowHeight * 1.5,
            tileHeight: Metrics.sidebarRowHeight + Metrics.space2, tileGap: Metrics.space2,
            iconButtonWidth: Metrics.sidebarRowHeight + Metrics.space2, lineWidth: Metrics.dividerThickness,
            favoriteHeight: Metrics.sidebarRowHeight * 2 + Metrics.space2,
            // A row glyph's center from a line's leading edge (the line
            // starts at the inset; the row glyph at twice the inset).
            glyphColumn: SidebarStyle.horizontalInset + SidebarStyle.iconBox / 2)
    }
}
