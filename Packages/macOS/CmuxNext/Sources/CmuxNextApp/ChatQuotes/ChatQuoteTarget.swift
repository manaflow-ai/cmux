/// The chat a viewer quote lands in (viewer-comments-DESIGN.md "Which chat gets it").
enum ChatQuoteTarget: Equatable, Sendable {
    /// The window's Chief Home chat.
    case chief
    /// The agent (ACP) chat tab with this key.
    case agentTab(String)
}
