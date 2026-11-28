public import CoreGraphics

/// Tabs follow the sidebar's workspace rows (Lawrence 2026-11-11: workspace rows and tab bar rows the same height
/// and roundness at every density; Lucas: the sidebar rows are the reference, Austin's Codex rows at Default, #39984).
/// Their one corner is Chrome's tab corner on that height (``chromeRowCornerRadius(height:)``).
/// The rows keep their own tokens; the tab pill and its strip read them here, so a row and a tab are one size by
/// default. `appearance.metrics.sidebarRowHeight` moves the rows alone (it is not read here), and an explicit tab
/// height or the tight tab strip keeps the tab's own size.
public extension Metrics {
    /// The density's one-line workspace row: its own `sidebarRowHeight` token, not the person's override, and at
    /// Default the Codex row's extra `space1` (`SidebarRowTokens.listRowHeight`: 28 + 2 = 30).
    static var densityRowHeight: CGFloat {
        let row = MetricTunables.sidebarRowHeight
        let height = scale(row.tunable.resolve(tokens.resolve(compact: row.compact, comfortable: row.comfortable, token: row.name)))
        return height + (tokens.usesDefaultRowFill ? space1 : 0)
    }

    /// ``densityRowHeight`` at Default, unscaled (30 pt): the reference the page density scale divides by.
    static var defaultDensityRowHeight: CGFloat {
        let row = MetricTunables.sidebarRowHeight, cozy = DensityPreset.cozy.tokens
        return cozy.resolve(compact: row.compact, comfortable: row.comfortable, token: row.name) + cozy.space(ChromeTunables.space1.value)
    }
}
