import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Compact (the default) and expanded keep the app tokens exactly. Comfortable
/// keeps one line per row and adds height and room, sized like the medium
/// sidebar size of the system's own sidebars (28 pt rows against the small
/// size's 24 pt), at the app's compact density:
///
/// | token                  | compact | comfortable | step              |
/// |------------------------|---------|-------------|-------------------|
/// | row, group             | 24      | 28          | + `space2`        |
/// | machine/section header | 22      | 26          | + `space2`        |
/// | row with a detail line | 37      | 41          | row + detail line |
/// | horizontal inset       | 6       | 8           | `space3`→`space4` |
/// | section gap            | 8       | 12          | `space4`→`space5` |
/// | list top padding       | 4       | 6           | `space2`→`space3` |
///
/// Row title and detail text size and weight do not change with density (Interface Size and
/// `sidebar.textSize` own the text size); `sidebar.textSize` (``SidebarTextSize``) adds its
/// `rowStep` to every row and header height here, on top of any density. A group header's name
/// keeps its existing rule and follows its bar (`SidebarStyle.groupHeaderFont`: 11 pt on the 24 pt row,
/// 12 pt on the 28 pt row). Row spacing stays `space1` so selection fills
/// keep their rhythm, and it is the only gap between rows: a group's or the
/// Pinned block's last row adds no padding (Leo 2026-10-21). Values are read at layout time, never cached, so a
/// change applies live.
enum SidebarDensityTokens {
    static var density: SidebarDensity { DesignSettings.shared.sidebarSections.density }
    static var isComfortable: Bool { density == .comfortable }
    /// `sidebar.textSize`: the list's text, leading glyphs and rows grow together.
    static var textSize: SidebarTextSize { DesignSettings.shared.sidebarSections.textSize }
    /// The extra height of a comfortable row or header, plus the text size's.
    private static var extra: CGFloat { (isComfortable ? Metrics.space2 : 0) + textSize.rowStep }

    /// A one-line workspace row, group header or band row.
    static var rowHeight: CGFloat { Metrics.sidebarRowHeight + extra }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20). With
    /// `SidebarTunables.evenRowText` off, the app's fixed step instead.
    static var rowHeightWithSubtitle: CGFloat {
        SidebarTunables.evenRowText.value ? rowHeight + SidebarStyle.detailLineHeight : Metrics.sidebarRowHeightWithSubtitle + extra
    }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge.
    static var horizontalInset: CGFloat { isComfortable ? Metrics.space4 : Metrics.space3 }
    static var iconBox: CGFloat { isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox }
    /// Compatibility name used by the existing session-tree layout. The tree's base indent is
    /// independent of the sidebar's group nesting grid and remains the original space4.
    static var depthIndent: CGFloat { Metrics.space4 }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density.
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
}
