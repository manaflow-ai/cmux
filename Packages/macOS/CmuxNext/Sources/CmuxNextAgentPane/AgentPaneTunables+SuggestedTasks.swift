public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Suggested tasks and nested child chats (cx-lo9yf): the acpmux daemon this app starts gets
    /// `ACPMUX_OFFER_TOOLS=1`, so every local session gets the cmux-sessions MCP server, and the
    /// page shows the suggestions. Read at each daemon start, so a toggle applies to the next one.
    public static let suggestedTasks = Tunable<Bool>.toggle(
        "agent.suggestedTasks", PageTunables.section, "Suggested tasks",
        help: "Agents can suggest follow-up tasks you start as child chats beside this one.",
        default: true, code: "AgentPaneTunables.suggestedTasks")
}
