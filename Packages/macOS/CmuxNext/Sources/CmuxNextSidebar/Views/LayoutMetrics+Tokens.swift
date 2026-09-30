import CmuxNextDesign
import CoreGraphics

extension SidebarLayoutMetrics {
    /// Full sidebar, from CmuxNextDesign density tokens.
    public static var standard: SidebarLayoutMetrics {
        SidebarLayoutMetrics(
            topPadding: Metrics.space2,
            bottomPadding: Metrics.space6,
            sectionHeaderHeight: Metrics.sidebarHeaderHeight,
            sectionSpacing: Metrics.space4,
            groupHeaderHeight: Metrics.sidebarRowHeight,
            rowHeight: Metrics.sidebarRowHeight,
            rowHeightWithSubtitle: Metrics.sidebarRowHeightWithSubtitle,
            rowSpacing: Metrics.space1,
            groupBottomPadding: Metrics.space3,
            emptySectionHeight: Metrics.sidebarRowHeight
        )
    }
}
