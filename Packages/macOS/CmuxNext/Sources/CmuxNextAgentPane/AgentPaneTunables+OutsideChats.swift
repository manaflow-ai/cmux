public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// On: Open on a Claude Code or Codex chat another app runs (All chats, the palette, a New Tab
    /// card) shows it View Only: its transcript at once, following that app, with Take Over and
    /// Continue in New Chat; a message sent from the composer takes it over. Off (the default): Open
    /// resumes it in place, ready to steer (Leo 2026-10-21: "I want it to steer by default"). View
    /// Chat Only (a row's menu, the palette, `cmux agent view`) still watches.
    public static let openOutsideChatsViewOnly = Tunable<Bool>.toggle(
        "agent.openOutsideChatsViewOnly", PageTunables.section, "Open outside chats View Only",
        help: "Opening a Claude Code or Codex chat another app runs shows it without taking it over until you reply or take it over.",
        default: false, code: "AgentPaneTunables.openOutsideChatsViewOnly")
}
