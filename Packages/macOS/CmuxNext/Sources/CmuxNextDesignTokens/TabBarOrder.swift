/// `tabs.barOrder` (R109): a browser pane's tab bar above or below its
/// toolbar (with the tab bar at the top).
public nonisolated enum TabBarOrder: String, Sendable, CaseIterable, Codable {
    /// The tab bar, then the toolbar (the default).
    case aboveToolbar
    /// The toolbar, then the tab bar, then the page.
    case belowToolbar
}
