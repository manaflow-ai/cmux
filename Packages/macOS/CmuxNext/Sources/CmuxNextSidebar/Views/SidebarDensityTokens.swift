import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Normal, the default, is the Codex desktop sidebar (https://github.com/manaflow-ai/cmux/issues/28793).
/// Every other density is Normal at its ``SidebarDensity/scale``, so all four keep Normal's proportions:
/// lengths in whole points, text in half points. Expanded takes Normal's one-line tokens and adds its second
/// line. At the app's compact density:
///
/// | token                  | ultra-compact | compact | normal | comfortable |
/// |------------------------|---------------|---------|--------|-------------|
/// | scale                  | 0.8           | 0.9     | 1      | 1.1         |
/// | row, group             | 22            | 25      | 28     | 31          |
/// | title / detail         | 10.5 / 9.5    | 11.5 / 11 | 13 / 12 | 14.5 / 13 |
/// | machine/section header | 18            | 20      | 22     | 24          |
/// | horizontal inset       | 6             | 7       | 8      | 9           |
/// | section gap            | 6             | 7       | 8      | 9           |
/// | list top padding       | 3             | 4       | 4      | 4           |
/// | icon box               | 13            | 14      | 16     | 18          |
///
/// `sidebar.textSize` (``SidebarTextSize``) adds its steps on top of any density. The custom sizes
/// (`sidebar.titleSize`, `sidebar.detailSize`, `sidebar.rowHeight`, `sidebar.rowPadding`) win over
/// both, exactly, in points at Interface Size 100%. `appearance.metrics.sidebarRowHeight` and a custom density's
/// `sidebarRowHeight` token set Normal's row, and the others scale from it. A group header's name
/// takes the rows' title size and regular weight (`SidebarStyle.groupHeaderFont`). Row spacing stays `space1` so selection fills
/// keep their rhythm, and it is the only gap between rows: a group's or the
/// Pinned block's last row adds no padding (Leo 2026-10-21). Values are read at layout time, never cached, so a
/// change applies live.
enum SidebarDensityTokens {
    static var preferences: SidebarSectionsPreferences { DesignSettings.shared.sidebarSections }
    static var density: SidebarDensity { preferences.density }
    /// A length at this density, in whole points.
    static func scaled(_ value: CGFloat) -> CGFloat { SidebarRowTokens.length(value, density: density) }
    /// `sidebar.textSize`: the list's text, leading glyphs and rows grow together.
    static var textSize: SidebarTextSize { preferences.textSize }
    /// The text size's steps over this density's sizes.
    static var textSteps: SidebarTextSize.Steps { SidebarRowTokens.current.textSteps }
    /// The text size's extra height on a row or header (``SidebarRowTokens``, which the sidebar's cards read too).
    private static var extra: CGFloat { SidebarRowTokens.current.extraHeight }

    /// A one-line workspace row, group header or band row: `sidebar.rowHeight` when set, else the
    /// list's Codex row at this density's scale plus the text size step.
    static var rowHeight: CGFloat { SidebarRowTokens.current.rowHeight }
    /// A workspace row with one detail line: the one-line row plus that line's height, so a row's
    /// text keeps the same room above and below with one line or more (Leo 2026-10-20).
    static var rowHeightWithSubtitle: CGFloat { rowHeight + SidebarStyle.detailLineHeight }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { scaled(Metrics.sidebarHeaderHeight) + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge: `SidebarRowTokens.horizontalInset`'s
    /// rule (`sidebar.rowPadding` when set; else Codex's 8 pt `--padding-row-x`, issue 28793, at this density's scale),
    /// read from its inputs. Every row frame reads it several times (`SidebarListView.frame(for:)`), and
    /// `SidebarRowTokens.current` builds the whole token set, fonts too, for each read.
    static var horizontalInset: CGFloat {
        if let padding = preferences.rowPadding { return Metrics.scale(padding) }
        return scaled(Metrics.space4)
    }
    static var iconBox: CGFloat { scaled(LayoutGrid.iconBox) }
    /// Compatibility name used by the existing session-tree layout. The tree's base indent is
    /// independent of the sidebar's group nesting grid and remains the original space4.
    static var depthIndent: CGFloat { Metrics.space4 }
    /// The corner radius of every row fill: pinned rows, group headers and workspace rows share it,
    /// so their fills line up at each density. It is the tab pill's radius (`Metrics.tabCornerRadius`),
    /// one token for both (Lawrence 2026-11-05: "workspace roundness needs to be same as tabs roundness").
    static var rowCornerRadius: CGFloat { Metrics.tabCornerRadius }
    static var sectionSpacing: CGFloat { scaled(Metrics.space4) }
    static var topPadding: CGFloat { scaled(Metrics.space2) }
}
