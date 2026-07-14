public import CMUXMobileCore

/// Immutable information rendered by one pane tab-strip card.
public struct PaneTabStripCardSnapshot: Equatable, Identifiable, Sendable {
    /// The stable mirrored surface identifier.
    public let id: String
    /// The Mac-displayed tab title, including custom renames.
    public let title: String
    /// The mirrored surface kind.
    public let kind: MobileWorkspaceTabKind
    /// Whether the surface is ready to render and accept interaction.
    public let isReady: Bool
    /// The effective coding-agent lifecycle, when known.
    public let agentStatus: MobileWorkspaceAgentStatus?
    /// Whether the Mac reports unread or bell activity for this surface.
    public let hasUnread: Bool

    /// Creates one immutable strip card snapshot.
    /// - Parameters:
    ///   - id: The stable mirrored surface identifier.
    ///   - title: The Mac-displayed tab title.
    ///   - kind: The mirrored surface kind.
    ///   - isReady: Whether the surface is ready.
    ///   - agentStatus: The effective coding-agent lifecycle, when known.
    ///   - hasUnread: Whether the surface reports unread or bell activity.
    public init(
        id: String,
        title: String,
        kind: MobileWorkspaceTabKind,
        isReady: Bool,
        agentStatus: MobileWorkspaceAgentStatus?,
        hasUnread: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isReady = isReady
        self.agentStatus = agentStatus
        self.hasUnread = hasUnread
    }
}
