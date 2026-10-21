public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// Open on a Claude Code or Codex chat another app runs (All chats, the palette, a New Tab card)
    /// shows it View Only: its transcript at once, following that app, with Take Over and Continue
    /// in New Chat; a message sent from the composer takes it over (Leo 2026-10-19: "view only is
    /// what you get when you don't act"). Off: Open resumes it in place, as before.
    public static let openOutsideChatsViewOnly = Tunable<Bool>.toggle(
        "agent.openOutsideChatsViewOnly", PageTunables.section, "Open outside chats View Only",
        help: "Opening a Claude Code or Codex chat another app runs shows it without taking it over until you reply or take it over.",
        default: true, code: "AgentPaneTunables.openOutsideChatsViewOnly")
}
