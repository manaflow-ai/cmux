import AppKit
import CmuxNextDesign
import CoreGraphics

extension SidebarLayoutMetrics {
    /// Full sidebar, from CmuxNextDesign density tokens.
    public static var standard: SidebarLayoutMetrics {
        var metrics = SidebarLayoutMetrics(
            topPadding: Metrics.space2,
            bottomPadding: Metrics.space6,
            sectionHeaderHeight: Metrics.sidebarHeaderHeight,
            sectionSpacing: Metrics.space4,
            groupHeaderHeight: Metrics.sidebarRowHeight,
            rowHeight: Metrics.sidebarRowHeight,
            rowHeightWithSubtitle: Metrics.sidebarRowHeightWithSubtitle,
            tabRowHeight: Metrics.sidebarRowHeight,
            rowSpacing: Metrics.space1,
            groupBottomPadding: Metrics.space3,
            emptySectionHeight: Metrics.sidebarRowHeight
        )
        let font = SidebarStyle.subtitleFont
        metrics.statusLineHeight = ceil(font.ascender - font.descender + font.leading) + Metrics.space1 / 2
        metrics.progressBarHeight = Metrics.space2
        metrics.statusBottomPadding = Metrics.space1
        return metrics
    }
}
