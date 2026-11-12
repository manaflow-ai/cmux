public import CoreGraphics

/// Tabs follow the sidebar's workspace rows (Lawrence 2026-11-11: workspace rows and tab bar rows the same height
/// and roundness at every density; Lucas: the sidebar rows are the reference, Austin's Codex rows at Default, #39984).
/// The rows keep their own tokens; the tab pill and its strip read them here, so a row and a tab are one size by
/// default. `appearance.metrics.sidebarRowHeight` moves the rows alone (it is not read here), and an explicit tab
/// height or the tight tab strip keeps the tab's own size.
public extension Metrics {
    /// The density's one-line workspace row: its own `sidebarRowHeight` token, not the person's override, and at
    /// Default the Codex row's extra `space1` (`SidebarRowTokens.listRowHeight`: 28 + 2 = 30).
    static var densityRowHeight: CGFloat {
        let row = MetricTunables.sidebarRowHeight
        let height = scale(row.tunable.resolve(tokens.resolve(compact: row.compact, comfortable: row.comfortable, token: row.name)))
        return height + (tokens.id == DensityPreset.cozy.rawValue ? space1 : 0)
    }

    /// Whether the tab pill takes ``densityRowHeight``: no explicit tab or tab strip height (a Debug tunable,
    /// `appearance.metrics.*` or a density's own token) and no tight tab strip. A set strip keeps the tab's own size
    /// in it, as before.
    static var tabsFollowRows: Bool {
        MetricTunables.tabHeight.explicitValue == nil && MetricTunables.tabStripHeight.explicitValue == nil && !compactTabs
    }

    /// How much taller the row-sized tab is than the density's own tab token: the strip grows by it, so the room
    /// around the pill stays the density's.
    static var tabRowGrowth: CGFloat { tabsFollowRows ? densityRowHeight - MetricTunables.tabHeight.value : 0 }

    /// The tab pill's corner when it follows the rows at Default: the Codex row's (a third of the row, 10 on 30).
    /// The sidebar rows read the tab's radius (`SidebarDensityTokens.rowCornerRadius`). Nil keeps the concentric tab
    /// radius: every other density, a corner setting (`layout.paneCornerRadius`, `layout.cornerPadding`) and Floating
    /// Panes, whose corners the tab nests in.
    static var tabRowCornerRadius: CGFloat? {
        let chrome = DesignSettings.shared.paneChrome
        guard tabsFollowRows, tokens.id == DensityPreset.cozy.rawValue, chrome.cornerRadius == nil,
              chrome.cornerPadding == nil, !floatingPanes else { return nil }
        return (tabHeight / 3).rounded()
    }
}
