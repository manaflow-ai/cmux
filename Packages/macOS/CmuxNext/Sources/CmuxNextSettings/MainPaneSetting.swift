/// Main pane layout (`layout.mainPane` in cmux.json, Leo 2026-10-20): a screen's agent chat is its
/// one main pane, and nothing opens into it. What the chat opens (a link, a file or folder, a
/// subagent's or a side chat's pane) is a tab in the column on its right; a chat alone on its screen
/// docks left the first time, so that column slides in beside it. Closing that column's last tab
/// gives the chat the whole width back.
///
/// ```jsonc
/// "layout": { "mainPane": "agent-chats" }   // "off"
/// ```
public nonisolated enum MainPaneSetting: String, Hashable, Sendable, CaseIterable {
    /// An agent chat is the main pane of its screen. The default.
    case agentChats = "agent-chats"
    /// No main pane: what a chat opens goes where `layout.linkPlacement` and the chat's own
    /// rules put it (a tab in the chat's pane, a split on its right).
    case off

    /// The cmux.json key.
    public static let configPath = ["layout", "mainPane"]
    /// ``agentChats`` when the key is unset or invalid.
    public static let fallback: MainPaneSetting = .agentChats
}
