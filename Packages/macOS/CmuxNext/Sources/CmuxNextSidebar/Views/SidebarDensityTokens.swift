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
/// takes the rows' title size and regular weight (`SidebarStyle.groupHeaderFont`). Row spacing stays `space1` so selection fills
/// keep their rhythm, and it is the only gap between rows: a group's or the
/// Pinned block's last row adds no padding (Leo 2026-10-21). Values are read at layout time, never cached, so a
/// change applies live.
enum SidebarDensityTokens {
    static var density: SidebarDensity { DesignSettings.shared.sidebarSections.density }
    static var isComfortable: Bool { density == .comfortable }
    /// `sidebar.textSize`: the list's text, leading glyphs and rows grow together.
    static var textSize: SidebarTextSize { DesignSettings.shared.sidebarSections.textSize }
    /// The extra height of a comfortable row or header, plus the text size's (``SidebarRowTokens``,
    /// which the sidebar's cards read too).
    private static var extra: CGFloat { SidebarRowTokens.current.extraHeight }

    /// A one-line workspace row, group header or band row.
    static var rowHeight: CGFloat { SidebarRowTokens.current.rowHeight }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20).
    static var rowHeightWithSubtitle: CGFloat { rowHeight + SidebarStyle.detailLineHeight }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge: `SidebarRowTokens.horizontalInset`'s
    /// rule, read from its two inputs. Every row frame reads it several times (`SidebarListView.frame(for:)`), and
    /// `SidebarRowTokens.current` builds the whole token set, fonts too, for each read.
    static var horizontalInset: CGFloat { isComfortable ? Metrics.space4 : Metrics.space3 }
    /// The padding between a one-line row's fill and its content on every side (Lawrence 2026-11-09: "for each
    /// workspace row, padding on left/bottom/top/right should be even, on all densities"): the room the row's title
    /// has above its capitals and below its baseline, which the row centers, so the first glyph, the last trailing box
    /// and the text all sit this far inside the fill. On the half-point grid. Read from the density's list row (one
    /// line, not Minimal Mode's shorter row) and the title font, so a text size or type scale change follows.
    static var contentInset: CGFloat {
        let row = Metrics.sidebarRowHeight + (isComfortable ? Metrics.space2 : 0) + textSize.rowStep
        return ((row - SidebarStyle.titleFont.capHeight) / 2 * 2).rounded() / 2
    }
    static var iconBox: CGFloat { isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox }
    /// Compatibility name used by the existing session-tree layout. The tree's base indent is
    /// independent of the sidebar's group nesting grid and remains the original space4.
    static var depthIndent: CGFloat { Metrics.space4 }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density. It is the tab pill's radius (`Metrics.tabCornerRadius`),
    /// one token for both (Lawrence 2026-11-05: "workspace roundness needs to be same as tabs roundness").
    static var rowCornerRadius: CGFloat { Metrics.tabCornerRadius }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
}
