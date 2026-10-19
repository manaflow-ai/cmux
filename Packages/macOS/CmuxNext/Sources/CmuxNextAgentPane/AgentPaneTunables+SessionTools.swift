public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Session tools for agents: every local session of the acpmux daemon this app starts gets
    /// `start_session`, `list_sessions`, `read_session` and `send_to_session` in its cmux-sessions
    /// MCP server. Off, the daemon gets `ACPMUX_SESSION_TOOLS=0`. Read at each daemon start, so a
    /// toggle applies to the next one.
    public static let sessionTools = Tunable<Bool>.toggle(
        "agent.sessionTools", PageTunables.section, "Session tools for agents",
        help: "Agents can start, list, read and message other agent sessions.",
        default: true, code: "AgentPaneTunables.sessionTools")
}
