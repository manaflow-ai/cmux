public import CMUXMobileCore

/// An immutable pane card rendered by the mobile workspace hub.
public struct WorkspaceHubPaneSnapshot: Equatable, Identifiable, Sendable {
    /// The stable pane identifier, or a stable terminal-derived fallback identifier.
    public let id: String
    /// The pane's normalized rectangle in the mirrored workspace.
    public let frame: WorkspaceHubPaneFrame
    /// The active tab's surface identifier, when the pane has a tab.
    public let activeSurfaceID: String?
    /// The active tab's displayed title.
    public let activeTitle: String
    /// Number of tabs in this pane.
    public let tabCount: Int
    /// The active tab's effective agent lifecycle.
    public let agentStatus: MobileWorkspaceAgentStatus?
    /// Whether the active tab carries unread activity.
    public let hasUnread: Bool
    /// Whether this pane contains the Mac's focused surface.
    public let focusState: WorkspaceHubFocusState
    /// Whether this card came from the legacy flat-terminal fallback.
    public let isFallback: Bool

    /// Creates an immutable hub pane snapshot.
    /// - Parameters:
    ///   - id: The stable pane identifier.
    ///   - frame: The normalized pane rectangle.
    ///   - activeSurfaceID: The active surface identifier.
    ///   - activeTitle: The active tab title.
    ///   - tabCount: The pane-local tab count.
    ///   - agentStatus: The active tab's agent lifecycle.
    ///   - hasUnread: Whether the active tab has unread activity.
    ///   - focusState: Whether the pane contains Mac focus.
    ///   - isFallback: Whether the snapshot represents a legacy flat terminal.
    public init(
        id: String,
        frame: WorkspaceHubPaneFrame,
        activeSurfaceID: String?,
        activeTitle: String,
        tabCount: Int,
        agentStatus: MobileWorkspaceAgentStatus?,
        hasUnread: Bool,
        focusState: WorkspaceHubFocusState,
        isFallback: Bool
    ) {
        self.id = id
        self.frame = frame
        self.activeSurfaceID = activeSurfaceID
        self.activeTitle = activeTitle
        self.tabCount = tabCount
        self.agentStatus = agentStatus
        self.hasUnread = hasUnread
        self.focusState = focusState
        self.isFallback = isFallback
    }
}
