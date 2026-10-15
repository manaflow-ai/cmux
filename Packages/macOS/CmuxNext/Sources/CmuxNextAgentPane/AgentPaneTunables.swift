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
    /// The session side rail beside the chat (cx-ncc.101): Environment, Context and Outputs, with a
    /// header button that shows and hides it. Off until it is promoted to a real setting.
    public static let sessionRail = Tunable<Bool>.toggle(
        "agent.sessionRail", PageTunables.section, "Session side rail",
        help: "A header button opens a rail beside the chat with its environment, context use and changed files.",
        default: false, code: "AgentPaneTunables.sessionRail")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, sessionRail.descriptor] }
}
