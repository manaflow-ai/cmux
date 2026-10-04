/// `sidebar.side` (R109): the window edge the sidebar sits on.
public nonisolated enum SidebarSide: String, Sendable, CaseIterable, Codable {
    /// The leading edge, under the traffic lights (the default).
    case left
    /// The trailing edge; the traffic lights then sit over the content.
    case right
}

/// `sidebar.spacesPosition` (R109): where the spaces dots sit in the
/// sidebar.
public nonisolated enum SpacesPosition: String, Sendable, CaseIterable, Codable {
    /// Under the titlebar row, above the top sections.
    case top
    /// Above the Settings and account row (the default).
    case bottom
}

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
