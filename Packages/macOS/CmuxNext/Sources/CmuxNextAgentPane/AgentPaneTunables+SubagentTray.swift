public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Where running subagents show in the agent pane (webviews acpmux subagents/runningTray.ts).
    /// On (the default), every running subagent and background command is a line in one tray right
    /// above the composer, and a subagent that ended leaves one line where it ended ("Subagent
    /// finished: <name> · 1m 20s") (Leo 2026-10-20: "put the subagent situation at the bottom of
    /// the chat and anchor"). Off keeps the older group card in the transcript where the subagents
    /// started and the agents pill above the composer. The page gets it with the theme
    /// (`AgentPaneTheme`, `subagentTray`): new agent tabs, and open ones on their next theme push.
    public static let subagentTray = Tunable<Bool>.toggle(
        "agentPane.debug.subagentTray", PageTunables.section, "Running subagents in a tray above the composer",
        help: "Running subagents and background commands show in one tray above the composer, and each subagent leaves one line where it ended. Off: a group card where they started and an agents pill.",
        default: true, code: "AgentPaneTunables.subagentTray")
}
