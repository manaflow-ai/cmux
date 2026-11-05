public import CmuxNextDesign

/// What a collapsed group header shows besides its name (Lawrence 2026-10-20: "All we care
/// about is the loading"): by default only a loading spinner, on the right. Each field turns one
/// more detail on.
public nonisolated struct GroupHeaderDetails: Hashable, Sendable {
    /// The member count after the name (`sidebar.groupHeader.memberCount`).
    public var memberCount = false
    /// The members' unread total on the right (`sidebar.groupHeader.unreadCount`).
    public var unreadCount = false
    /// The members' other states (waiting, error, done) beside loading
    /// (`sidebar.detailedStatusIcons`).
    public var otherStates = false
    /// How the header's background draws (`sidebar.groupHeader.background`): glass, solid, or glass only where
    /// the sidebar is see-through. It always shows (``GroupBackground``).
    public var background: SidebarGroupBackgroundStyle = .auto

    /// Details with every field off but the ones given.
    /// - Parameters:
    ///   - memberCount: Show the member count after the name.
    ///   - unreadCount: Show the unread total on the right.
    ///   - otherStates: Show states other than loading.
    ///   - background: How the background draws; glass where the sidebar is see-through by default.
    public init(memberCount: Bool = false, unreadCount: Bool = false, otherStates: Bool = false,
                background: SidebarGroupBackgroundStyle = .auto) {
        self.memberCount = memberCount
        self.unreadCount = unreadCount
        self.otherStates = otherStates
        self.background = background
    }
}
