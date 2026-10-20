public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// The runaway guard for agent-to-agent messages (acpmux `hub/agent_pairs.rs`): two agent
    /// sessions that keep messaging each other without a tool call or file change in between, or
    /// that keep sending the same message, are paused until the person resumes them. Off, the
    /// daemon this app starts gets `ACPMUX_AGENT_PAIR_GUARD=0`. Read at each daemon start, so a
    /// toggle applies to the next one.
    public static let agentPairGuard = Tunable<Bool>.toggle(
        "agent.pairGuard", PageTunables.section, "Pause agents messaging in a loop",
        help: "Two agents that keep messaging each other without making progress are paused until you resume them.",
        default: true, code: "AgentPaneTunables.agentPairGuard")
}
