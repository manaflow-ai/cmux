import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Row heights keep the existing metric tunables (24/32 by interface density). The highlight
/// leaves two points above and below; column alignment does not choose the row density.
enum SidebarDensityTokens {
    static var density: SidebarDensity { DesignSettings.shared.sidebarSections.density }
    static var isComfortable: Bool { density == .comfortable }
    /// The extra height of a comfortable row or header.
    private static var extra: CGFloat { isComfortable ? Metrics.space2 : 0 }

    /// A one-line workspace row, tab row, group header or band row.
    static var rowHeight: CGFloat { Metrics.sidebarRowHeight }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20). With
    /// `SidebarTunables.evenRowText` off, the app's fixed step instead.
    static var rowHeightWithSubtitle: CGFloat {
        SidebarTunables.evenRowText.value ? rowHeight + SidebarStyle.detailLineHeight : Metrics.sidebarRowHeightWithSubtitle + extra
    }
    /// Preserve the group label typography while its row moves to the grid.
    static var groupLabelReferenceHeight: CGFloat { Metrics.sidebarRowHeight + extra }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge.
    static var horizontalInset: CGFloat { LayoutGrid.sidebarHighlightInset }
    static var iconBox: CGFloat { isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox }
    static var depthIndent: CGFloat { LayoutGrid.sidebarDepthIndent }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density.
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
}
