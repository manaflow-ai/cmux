import AppKit
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
            progressBarHeight: Metrics.space3,
            minimumStatusLineHeight: ceil(Typography.caption.pointSize) + 1,
            rowSpacing: Metrics.space1,
            groupBottomPadding: Metrics.space3,
            emptySectionHeight: Metrics.sidebarRowHeight
        )
    }
}
