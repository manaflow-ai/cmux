/// One ordered Mac-owned tab inside a mirrored pane.
public struct MobileWorkspaceTab: Codable, Equatable, Identifiable, Sendable {
    /// The stable surface identifier, matching the existing mobile terminal id for terminal tabs.
    public var id: String
    /// The Mac-displayed tab name.
    public var name: String
    /// Whether the surface is a terminal or browser.
    public var kind: MobileWorkspaceTabKind
    /// Whether this is the pane's selected tab.
    public var isActive: Bool
    /// Whether the surface is ready to render and accept interaction.
    public var isReady: Bool
    /// The effective agent lifecycle, or `nil` when the tab has no known agent.
    public var agentStatus: MobileWorkspaceAgentStatus?
    /// Whether the Mac tab currently carries an unread/activity badge.
    public var hasUnread: Bool

    /// Creates a mirrored workspace tab.
    /// - Parameters:
    ///   - id: The stable surface identifier.
    ///   - name: The displayed tab name.
    ///   - kind: The mirrored surface kind.
    ///   - isActive: Whether this tab is selected in its pane.
    ///   - isReady: Whether the surface is ready.
    ///   - agentStatus: The effective agent lifecycle, when applicable.
    ///   - hasUnread: Whether the tab carries an unread/activity badge.
    public init(
        id: String,
        name: String,
        kind: MobileWorkspaceTabKind,
        isActive: Bool,
        isReady: Bool,
        agentStatus: MobileWorkspaceAgentStatus? = nil,
        hasUnread: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isActive = isActive
        self.isReady = isReady
        self.agentStatus = agentStatus
        self.hasUnread = hasUnread
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case isActive = "is_active"
        case isReady = "is_ready"
        case agentStatus = "agent_status"
        case hasUnread = "has_unread"
    }
}
