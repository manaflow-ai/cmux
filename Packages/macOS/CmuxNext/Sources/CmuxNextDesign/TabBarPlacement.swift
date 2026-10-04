/// `tabs.barPosition` (R109): the edge of each pane its tab bar sits on.
public nonisolated enum TabBarPosition: String, Sendable, CaseIterable, Codable {
    /// Above the pane's content (the default).
    case top
    /// Below the pane's content; the window then uses the standard title
    /// bar, so the traffic lights never sit over content.
    case bottom
}

/// `tabs.barOrder` (R109): a browser pane's tab bar above or below its
/// toolbar (with the tab bar at the top).
public nonisolated enum TabBarOrder: String, Sendable, CaseIterable, Codable {
    /// The tab bar, then the toolbar (the default).
    case aboveToolbar
    /// The toolbar, then the tab bar, then the page.
    case belowToolbar
}
