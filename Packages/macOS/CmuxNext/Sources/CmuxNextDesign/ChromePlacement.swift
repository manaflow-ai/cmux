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
