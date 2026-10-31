import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Compact (the default) and expanded keep the sidebar's list tokens exactly; compact
/// matches the Codex desktop sidebar (issue 28793): 13 pt titles at weight 430, 12 pt
/// detail lines, one-line rows on a 30 pt pitch (a 28 pt row and the `space1` gap) and
/// 8 pt horizontal padding. Comfortable keeps one line per row and adds height and room
/// on top, at the app's compact density:
///
/// | token                  | compact | comfortable | step                      |
/// |------------------------|---------|-------------|---------------------------|
/// | row, tab row, group    | 28      | 32          | + `space2`                |
/// | machine/section header | 22      | 26          | + `space2`                |
/// | row with a detail line | 43      | 47          | row + detail line         |
/// | horizontal inset       | 8       | 10          | `space4`→`space4`+`space1` |
/// | section gap            | 8       | 12          | `space4`→`space5`         |
/// | list top padding       | 4       | 6           | `space2`→`space3`         |
///
/// The row height is `Metrics.sidebarListRowHeight`, so `appearance.metrics.sidebarRowHeight`
/// and a custom density's `sidebarRowHeight` token still set it. Row title and detail text
/// size and weight do not change with density (Interface Size and `sidebar.textSize` own the
/// text size); `sidebar.textSize` (``SidebarTextSize``) adds its `rowStep` to every row and
/// header height here, on top of any density. A group header's name keeps its existing rule and
/// follows its bar (`SidebarStyle.groupHeaderFont`: 12 pt on the 28 pt row, 13 pt on the 32 pt row). Row spacing stays `space1` so selection fills
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

    /// A one-line workspace row, tab row, group header or band row.
    static var rowHeight: CGFloat { Metrics.sidebarListRowHeight + extra }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20). With
    /// `SidebarTunables.evenRowText` off, the app's fixed step over a one-line row instead.
    static var rowHeightWithSubtitle: CGFloat {
        SidebarTunables.evenRowText.value
            ? rowHeight + SidebarStyle.detailLineHeight
            : rowHeight + Metrics.sidebarSubtitleStep
    }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge.
    /// Codex's 8 pt `--padding-row-x` at compact (issue 28793); comfortable stays roomier.
    static var horizontalInset: CGFloat { isComfortable ? Metrics.space4 + Metrics.space1 : Metrics.space4 }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density.
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
}
