public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// A sub-session an agent chat's agent starts opens as a tab beside that chat (its side pane,
    /// else a split right of it), without taking focus (`AgentSubsessionAutoOpen`). On by default;
    /// off leaves new sub-sessions in the sidebar until someone opens one.
    public static let subsessionAutoOpen = Tunable<Bool>.toggle(
        "agent.subsessionAutoOpen", PageTunables.section, "Open sub-sessions beside their chat",
        help: "A new sub-session opens as a tab beside the chat that started it, without moving focus.",
        default: true, code: "AgentPaneTunables.subsessionAutoOpen")
}
