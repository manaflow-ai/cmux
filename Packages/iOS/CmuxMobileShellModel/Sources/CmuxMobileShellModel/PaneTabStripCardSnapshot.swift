public import CMUXMobileCore

/// Immutable information rendered by one pane tab-strip card.
public struct PaneTabStripCardSnapshot: Equatable, Identifiable, Sendable {
    /// Stable card identity. Chat and local-browser ids are namespaced.
    public let id: String
    /// The underlying terminal, browser, or chat-session identifier.
    public let sourceID: String
    /// The Mac-displayed tab title, including custom renames.
    public let title: String
    /// The client-visible card kind.
    public let kind: PaneTabCardKind
    /// The bound terminal for an agent-chat card.
    public let boundTerminalID: String?
    /// Whether the surface is ready to render and accept interaction.
    public let isReady: Bool
    /// The effective coding-agent lifecycle, when known.
    public let agentStatus: MobileWorkspaceAgentStatus?
    /// Whether the Mac reports unread or bell activity for this surface.
    public let hasUnread: Bool

    /// Creates one immutable strip card snapshot.
    /// - Parameters:
    ///   - id: The stable mirrored surface identifier.
    ///   - sourceID: The underlying surface or session identifier.
    ///   - title: The displayed card title.
    ///   - kind: The client-visible card kind.
    ///   - boundTerminalID: The bound terminal for an agent-chat card.
    ///   - isReady: Whether the surface is ready.
    ///   - agentStatus: The effective coding-agent lifecycle, when known.
    ///   - hasUnread: Whether the surface reports unread or bell activity.
    public init(
        id: String,
        sourceID: String? = nil,
        title: String,
        kind: PaneTabCardKind = .terminal,
        boundTerminalID: String? = nil,
        isReady: Bool,
        agentStatus: MobileWorkspaceAgentStatus?,
        hasUnread: Bool
    ) {
        self.id = id
        self.sourceID = sourceID ?? id
        self.title = title
        self.kind = kind
        self.boundTerminalID = boundTerminalID
        self.isReady = isReady
        self.agentStatus = agentStatus
        self.hasUnread = hasUnread
    }
}
