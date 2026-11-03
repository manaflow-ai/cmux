import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Normal, the default, is the Codex desktop sidebar (https://github.com/manaflow-ai/cmux/issues/28793):
/// 13 pt titles at weight 430, 12 pt detail lines, one-line rows on a 30 pt pitch (a 28 pt row and the
/// `space1` gap) and 8 pt horizontal padding. Compact is the sidebar from before it, unchanged for
/// whoever picked it: the app's 24 pt row, `Typography.body` titles and caption details, a 6 pt inset.
/// Comfortable is Normal with more room: taller rows, the wider icon box, bigger section gaps. Expanded
/// takes Normal's one-line tokens and adds its second line. At the app's compact density:
///
/// | token                  | compact | normal | comfortable | rule                         |
/// |------------------------|---------|--------|-------------|------------------------------|
/// | row, group             | 24      | 28     | 32          | normal + `space2`            |
/// | row pitch (+ `space1`) | 26      | 30     | 34          |                              |
/// | title / detail         | 12 / 10.5 | 13 / 12 | 13 / 12  | `body`/`caption`, `sidebarRow`/`sidebarDetail` |
/// | machine/section header | 22      | 22     | 26          | + `space2`                   |
/// | horizontal inset       | 6       | 8      | 8           | `space3`, `space4`           |
/// | section gap            | 8       | 8      | 12          | `space4`→`space5`            |
/// | list top padding       | 4       | 4      | 6           | `space2`→`space3`            |
///
/// `sidebar.textSize` (``SidebarTextSize``) adds its steps on top of any density. The custom sizes
/// (`sidebar.titleSize`, `sidebar.detailSize`, `sidebar.rowHeight`, `sidebar.rowPadding`) win over
/// both, exactly, in points at Interface Size 100%. `appearance.metrics.sidebarRowHeight` and a custom
/// density's `sidebarRowHeight` token still set the Normal and Compact rows. A group header's name
/// keeps its existing rule and follows its bar (`SidebarStyle.groupHeaderFont`). Row spacing stays `space1` so selection fills
/// keep their rhythm, and it is the only gap between rows: a group's or the
/// Pinned block's last row adds no padding (Leo 2026-10-21). Values are read at layout time, never cached, so a
/// change applies live.
enum SidebarDensityTokens {
    static var preferences: SidebarSectionsPreferences { DesignSettings.shared.sidebarSections }
    static var density: SidebarDensity { preferences.density }
    static var isComfortable: Bool { density == .comfortable }
    /// Compact: the sidebar's look before Normal (the app's row and type), kept exactly.
    static var isCompact: Bool { density == .compact }
    /// `sidebar.textSize`: the list's text, leading glyphs and rows grow together.
    static var textSize: SidebarTextSize { preferences.textSize }
    /// The text size's steps over this density's sizes (Compact steps from its own smaller base).
    static var textSteps: SidebarTextSize.Steps { SidebarRowTokens.current.textSteps }
    /// The extra height of a comfortable row or header, plus the text size's (``SidebarRowTokens``,
    /// which the sidebar's cards read too).
    private static var extra: CGFloat { SidebarRowTokens.current.extraHeight }

    /// A one-line workspace row, group header or band row: `sidebar.rowHeight` when set, else the
    /// density's (Compact the app's row, the others the list's Codex row) plus the comfortable and text size steps.
    static var rowHeight: CGFloat { SidebarRowTokens.current.rowHeight }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20). With
    /// `SidebarTunables.evenRowText` off, the app's fixed step over a one-line row instead (Compact: the app's
    /// detail row, as before Normal, even under a Debug override of the one-line row).
    static var rowHeightWithSubtitle: CGFloat {
        SidebarTunables.evenRowText.value
            ? rowHeight + SidebarStyle.detailLineHeight
            : isCompact ? Metrics.sidebarRowHeightWithSubtitle + extra : rowHeight + Metrics.sidebarSubtitleStep
    }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge: `sidebar.rowPadding` when set;
    /// else Codex's 8 pt `--padding-row-x` (issue 28793; the grid's comfortable inset too), 6 pt at Compact.
    static var horizontalInset: CGFloat { SidebarRowTokens.current.horizontalInset }
    static var iconBox: CGFloat { isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox }
    /// Compatibility name used by the existing session-tree layout. The tree's base indent is
    /// independent of the sidebar's group nesting grid and remains the original space4.
    static var depthIndent: CGFloat { Metrics.space4 }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density. One `space1` rounder than the app's item corner (8 compact,
    /// 9 comfortable), near ChatGPT's soft row corner for its height (about 9 to 10 pt on a 30 pt row).
    /// Leo 2026-11-02: "SMOOTH OUT A BIT MORE OF OUR CORNERS ON THE SIDEBAR WORKSPACES".
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius + Metrics.space1 }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
}
