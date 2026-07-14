public import CMUXMobileCore

/// Immutable chat-session metadata injected beside Mac-authored pane tabs.
public struct PaneChatCardSnapshot: Equatable, Identifiable, Sendable {
    /// The chat session identifier.
    public let id: String
    /// The terminal surface this conversation belongs to.
    public let terminalID: String
    /// The session's display title.
    public let title: String
    /// The agent's projected running, waiting, idle, or unknown state.
    public let agentStatus: MobileWorkspaceAgentStatus

    /// Creates one client-side chat card input.
    /// - Parameters:
    ///   - id: The chat session identifier.
    ///   - terminalID: The bound terminal surface identifier.
    ///   - title: The session's display title.
    ///   - agentStatus: The projected agent lifecycle.
    public init(
        id: String,
        terminalID: String,
        title: String,
        agentStatus: MobileWorkspaceAgentStatus
    ) {
        self.id = id
        self.terminalID = terminalID
        self.title = title
        self.agentStatus = agentStatus
    }
}
