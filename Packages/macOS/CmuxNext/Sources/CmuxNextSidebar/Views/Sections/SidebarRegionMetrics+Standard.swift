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
    @MainActor static func standard(minimal: Bool) -> SidebarRegionMetrics {
        minimal ? standard(rowHeight: SidebarLayoutMetrics.standard.minimal.rowHeight) : standard
    }

    @MainActor private static func standard(rowHeight row: CGFloat) -> SidebarRegionMetrics {
        SidebarRegionMetrics(
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
            // starts at the inset; the row glyph at twice the inset).
            glyphColumn: SidebarStyle.horizontalInset + SidebarStyle.iconBox / 2)
    }
}
