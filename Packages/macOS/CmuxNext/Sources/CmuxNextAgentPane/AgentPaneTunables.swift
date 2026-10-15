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

    /// Suggested tasks and nested child chats (cx-lo9yf): the acpmux daemon this app starts gets
    /// `ACPMUX_OFFER_TOOLS=1`, so every local session gets the cmux-sessions MCP server, and the
    /// page shows the suggestions. Read at each daemon start, so a toggle applies to the next one.
    public static let suggestedTasks = Tunable<Bool>.toggle(
        "agent.suggestedTasks", PageTunables.section, "Suggested tasks",
        help: "Agents can suggest follow-up tasks you start as child chats beside this one.",
        default: false, code: "AgentPaneTunables.suggestedTasks")

    public static var all: [TunableDescriptor] { [pageHost.descriptor, suggestedTasks.descriptor] }
}
