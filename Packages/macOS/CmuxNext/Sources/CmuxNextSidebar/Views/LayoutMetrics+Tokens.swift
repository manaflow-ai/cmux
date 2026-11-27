import AppKit
import CmuxNextDesign
import CoreGraphics

extension SidebarLayoutMetrics {
    /// Full sidebar, from CmuxNextDesign density tokens and the sidebar's own
    /// density (`sidebar.density`, `SidebarDensityTokens`): pinned rows, group
    /// headers and machine headers all take the same row step.
    public static var standard: SidebarLayoutMetrics {
        let row = SidebarDensityTokens.rowHeight
        var metrics = SidebarLayoutMetrics(
            topPadding: SidebarDensityTokens.topPadding,
            bottomPadding: Metrics.space6,
            sectionHeaderHeight: SidebarDensityTokens.headerHeight,
            sectionSpacing: SidebarDensityTokens.sectionSpacing,
            rowHeight: row,
            rowHeightWithSubtitle: SidebarDensityTokens.rowHeightWithSubtitle,
            rowSpacing: SidebarDensityTokens.rowSpacing,
            emptySectionHeight: row
        )
        let pitch = statusPitch
        metrics.statusLineHeight = pitch.line
        metrics.progressBarHeight = pitch.bar
        metrics.statusBottomPadding = Metrics.space1
        return metrics
    }

    /// The status block's line pitch and the height of the progress bar's slot, as `standard` has them, alone: a row's
    /// status block places its lines with these two at each layout, and `standard` reads the sidebar's density tokens
    /// for every other field too (a read of the design tokens for each row of each layout pass).
    static var statusPitch: (line: CGFloat, bar: CGFloat) {
        let font = SidebarStyle.subtitleFont
        return (ceil(font.ascender - font.descender + font.leading) + Metrics.space1 / 2, Metrics.space2)
    }
}
