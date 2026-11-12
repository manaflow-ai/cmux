import CmuxNextDesign
import CoreGraphics

extension SidebarRegionMetrics {
    /// From the design tokens, read at layout time so density applies live.
    /// The band rows (pinned items, tiles) take the list's row step for
    /// `sidebar.density` (`SidebarDensityTokens`).
    @MainActor static var standard: SidebarRegionMetrics { standard(rowHeight: SidebarDensityTokens.rowHeight) }

    /// The bands above the list in Minimal Mode (`sidebar.minimal`): their rows (Home, App Store, pinned
    /// items) take the list's minimal row height, so a pinned row is as tall as the workspace rows and
    /// group headers under it at every density (Lawrence 2026-10-22). They were 24 pt over 20 pt rows.
    /// Otherwise their rows are the band's (``SidebarRowTokens/band``): at Expanded, Comfortable's 28 pt
    /// row, not the app's one-line 24 pt under 37 pt list rows (Lawrence 2026-11-04).
    @MainActor static func standard(minimal: Bool) -> SidebarRegionMetrics {
        standard(rowHeight: minimal ? SidebarLayoutMetrics.standard.minimal.rowHeight : SidebarRowTokens.current.band.listRowHeight)
    }

    @MainActor private static func standard(rowHeight row: CGFloat) -> SidebarRegionMetrics {
        var metrics = SidebarRegionMetrics(
            rowHeight: row, headerHeight: SidebarDensityTokens.headerHeight,
            // Keep the pinned footer clear of the window's rounded lower
            // corner. The same grid step as the row's horizontal breathing
            // room keeps the Settings and account destinations aligned with
            // the top of the sidebar.
            inset: SidebarStyle.horizontalInset, sectionGap: Metrics.space2, padding: Metrics.space2,
            cardPadding: Metrics.space1, tileMinWidth: row * 1.5,
            tileHeight: row + Metrics.space2, tileGap: Metrics.space2,
            iconButtonWidth: row + Metrics.space2, lineWidth: Metrics.dividerThickness,
            favoriteHeight: row * 2 + Metrics.space2,
            // A row glyph's center from a line's leading edge (the line
            // starts at the inset; the row glyph the content inset past it).
            glyphColumn: SidebarStyle.contentInset + SidebarStyle.iconColumnBox / 2)
        // Home and the pinned rows step at the workspace rows' pitch: the list's row gap between two rows
        // (`space1` at every density since #41212; Lawrence 2026-11-11).
        metrics.rowGap = SidebarDensityTokens.rowSpacing
        return metrics
    }
}
