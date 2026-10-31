public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Forces suggested tasks and nested child chats (cx-lo9yf) on, whatever the setting
    /// `sessions.promptSuggestions` says (``AgentPaneSuggestedTasks``): the acpmux daemon this app
    /// starts gets `ACPMUX_OFFER_TOOLS=1`, so every local session gets the cmux-sessions MCP server,
    /// and the page shows the suggestions. Off by default, so the setting decides. Read at each
    /// daemon start, so a toggle applies to the next one.
    public static let suggestedTasks = Tunable<Bool>.toggle(
        "agent.suggestedTasks", PageTunables.section, "Force suggested tasks on",
        help: "Agents suggest follow-up tasks even with Suggest Follow-Up Tasks off in Settings.",
        default: false, code: "AgentPaneTunables.suggestedTasks")
}
