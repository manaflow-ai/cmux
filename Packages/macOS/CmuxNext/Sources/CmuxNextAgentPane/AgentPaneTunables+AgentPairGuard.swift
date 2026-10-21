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

    /// The guard's cap: two agents that exchange more than this many messages within
    /// ``agentPairWindow`` with no prompt from the person are paused (`ACPMUX_AGENT_PAIR_MAX_MESSAGES`).
    public static let agentPairCap = Tunable<Double>.number(
        "agent.pairCap", PageTunables.section, "Agent message cap",
        help: "Messages two agents may exchange without you. 0 is off.",
        default: 20, range: 0...200, step: 1, unit: .count, code: "AgentPaneTunables.agentPairCap")

    /// The window ``agentPairCap`` counts over (`ACPMUX_AGENT_PAIR_WINDOW_SECS`).
    public static let agentPairWindow = Tunable<Double>.number(
        "agent.pairWindow", PageTunables.section, "Agent message window",
        help: "How long the cap counts. 0 is off.",
        default: 600, range: 0...3600, step: 60, unit: .seconds, code: "AgentPaneTunables.agentPairWindow")
}
