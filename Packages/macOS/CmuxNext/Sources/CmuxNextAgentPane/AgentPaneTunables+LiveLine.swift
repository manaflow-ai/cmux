public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Where a running turn's status line draws (webviews conversation/turns.ts `liveTurn`). On
    /// (the default), it is the turn's last row, as Claude desktop draws it: what
    /// the agent is doing now and the turn's time, ticking until the turn ends, so the bottom of a
    /// running chat always moves. Off keeps the older line over the turn's work, whose clock stops
    /// while text streams. The page gets it with the theme (`AgentPaneTheme`, `liveLineBelow`),
    /// again on each change.
    public static let liveLineBelow = Tunable<Bool>.toggle(
        "agentPane.debug.liveLineBelow", PageTunables.section, "Running turn's status line at the bottom",
        help: "While a turn runs, its status line (what the agent is doing and a ticking time) is the turn's last row instead of a line over its work.",
        default: true, code: "AgentPaneTunables.liveLineBelow")
}
