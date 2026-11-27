/// Vertical tabs in cmux.json (Leo 2026-10-20: "a per-workspace Vertical tabs option, off by default,
/// and a Use vertical tabs for all workspaces control"):
/// - `tabs.verticalTabs`: every workspace shows its tabs as a vertical list beside its panes, unless the
///   workspace turned them off itself. Off by default: tabs stay a horizontal strip.
/// - `tabs.verticalTabsExpandOnHover`: a collapsed list (icons only) widens to show titles while the
///   pointer is over it, as Chrome's and Edge's do. On by default.
/// The tab list's empty-area menu (Use Vertical Tabs for All Workspaces, Auto-Expand Tabs on Hover),
/// the palette and Settings write them.
public nonisolated struct VerticalTabsSetting: Sendable {
    public init() {}
}
