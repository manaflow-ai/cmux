import CmuxNextAgentActivity

/// Where picking a lane in the sidebar's Priority view puts its chat. It is a
/// value so the choice can be read without the app's services, which
/// ``AgentActivityPageService/jump(to:)`` then carries out.
enum AgentChatJump: Equatable {
    /// A tab of this app already shows the chat: reveal it where it lives.
    case revealTab(String)
    /// No tab shows it and the lane names a workspace this app has: show that
    /// workspace, then open the chat in a pane of its own.
    case openInWorkspace(workspaceID: String, session: String)
    /// Nothing says where the chat belongs (the session carries no workspace,
    /// or this app does not have that one): the focused pane, the path every
    /// `cmux://session/<id>` link takes.
    case openInFocusedPane(session: String)

    /// - Parameters:
    ///   - lane: The lane the person picked.
    ///   - tab: The tab already showing the lane's session, if any
    ///     (``AgentTabStore/tab(showing:host:)``).
    ///   - hasWorkspace: Whether this app has the workspace with that id.
    static func decide(lane: AgentActivityLane, shownIn tab: String?,
                       hasWorkspace: (String) -> Bool) -> AgentChatJump {
        if let tab { return .revealTab(tab) }
        if let workspaceID = lane.workspaceID, hasWorkspace(workspaceID) {
            return .openInWorkspace(workspaceID: workspaceID, session: lane.id)
        }
        return .openInFocusedPane(session: lane.id)
    }

    /// What an ``openInWorkspace(workspaceID:session:)`` jump does when its window shows the
    /// workspace before any of that workspace's panes has mounted.
    enum PaneWait: Equatable, Sendable {
        /// A pane mounted: open the chat there.
        case open
        /// None yet: wait for the next mount.
        case wait
        /// The window closed or shows another workspace: the jump is over.
        case stop

        /// - Parameters:
        ///   - showing: The workspace the jump's window shows now, nil once it closed.
        ///   - workspaceID: The workspace the jump went to.
        ///   - hasPane: Whether that window has a pane yet.
        static func decide(showing: String?, workspaceID: String, hasPane: Bool) -> PaneWait {
            guard showing == workspaceID else { return .stop }
            return hasPane ? .open : .wait
        }
    }
}
