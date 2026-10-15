public import CmuxNextDesign
import CmuxNextPages

/// Debug Settings declarations of the agent pane (DEV and NIGHTLY).
public nonisolated struct AgentPaneTunables {
    public nonisolated init() {}
    /// The agent pane move (react-pages.md): host new agent tabs on the shared page host
    /// (`cmux-page://cmux.agent/`) instead of the pane's own host. Off until the move is done; this
    /// tunable goes with the old host (P5).
    public static let pageHost = Tunable<Bool>.toggle(
        "agent.pageHost", PageTunables.section, "Agent pane on the page host",
        help: "New agent tabs load cmux-page://cmux.agent/ on the shared page host.",
        default: false, code: "AgentPaneTunables.pageHost")

    /// Claude Code desktop's in-session status in an agent chat: the live plan card and the recap
    /// card. Off by default; each open agent page follows a change (``AgentPaneView/sessionStatus``).
    public static let sessionStatus = Tunable<Bool>.toggle(
        "agent.sessionStatus", PageTunables.section, "In-session status (plan card, recap card)",
        help: "Agent chats show the live plan card and the recap card.",
        default: false, code: "AgentPaneTunables.sessionStatus")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, sessionStatus.descriptor] }
}
