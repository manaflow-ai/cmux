import CmuxNextDesign
import CoreGraphics

extension SidebarLayoutMetrics {
    /// Full sidebar, from CmuxNextDesign density tokens.
    public static var standard: SidebarLayoutMetrics {
        SidebarLayoutMetrics(
            topPadding: Metrics.space2,
            bottomPadding: Metrics.space6,
            sectionHeaderHeight: Metrics.sidebarHeaderHeight,
            sectionSpacing: Metrics.space5,
            groupHeaderHeight: Metrics.sidebarRowHeight,
            rowHeight: Metrics.sidebarRowHeight,
            rowHeightWithSubtitle: Metrics.sidebarRowHeightWithSubtitle,
            rowSpacing: Metrics.space1,
            groupBottomPadding: Metrics.space3,
            emptySectionHeight: Metrics.sidebarRowHeight
        )
    }

    /// Icons-only sidebar: square rows, section headers shrink to separators.
    public static var iconsOnly: SidebarLayoutMetrics {
        let row = Metrics.sidebarCollapsedWidth - Metrics.space4
        return SidebarLayoutMetrics(
            topPadding: Metrics.space1,
            bottomPadding: Metrics.space5,
            sectionHeaderHeight: Metrics.space5,
            sectionSpacing: Metrics.space2,
            groupHeaderHeight: row,
            rowHeight: row,
            rowHeightWithSubtitle: row,
            rowSpacing: Metrics.space1,
            groupBottomPadding: Metrics.space1,
            emptySectionHeight: row
        )
    }
}
