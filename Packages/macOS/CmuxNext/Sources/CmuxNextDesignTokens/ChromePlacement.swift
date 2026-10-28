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
    /// A vertical column of tabs on the pane's left edge (prototype, user
    /// 2026-10-27); the window uses the standard title bar, as for bottom.
    case left
    /// A vertical column of tabs on the pane's right edge (prototype).
    case right

    /// Left or right: the pane shows its tabs as a vertical column.
    public var isVertical: Bool { self == .left || self == .right }
}
