import AppKit
import CmuxNextDesign
import CoreGraphics

extension SidebarLayoutMetrics {
    /// Full sidebar, from CmuxNextDesign density tokens and the sidebar's own
    /// density (`sidebar.density`, `SidebarDensityTokens`): pinned rows, group
    /// headers, machine headers and tab rows all take the same row step.
    public static var standard: SidebarLayoutMetrics {
        let row = SidebarDensityTokens.rowHeight
        var metrics = SidebarLayoutMetrics(
            topPadding: SidebarDensityTokens.topPadding,
            bottomPadding: Metrics.space6,
            sectionHeaderHeight: SidebarDensityTokens.headerHeight,
            sectionSpacing: SidebarDensityTokens.sectionSpacing,
            rowHeight: row,
            rowHeightWithSubtitle: SidebarDensityTokens.rowHeightWithSubtitle,
            tabRowHeight: row,
            rowSpacing: Metrics.space1,
            emptySectionHeight: row
        )
        let font = SidebarStyle.subtitleFont
        metrics.statusLineHeight = ceil(font.ascender - font.descender + font.leading) + Metrics.space1 / 2
        metrics.progressBarHeight = Metrics.space2
        metrics.statusBottomPadding = Metrics.space1
        return metrics
    }
}
