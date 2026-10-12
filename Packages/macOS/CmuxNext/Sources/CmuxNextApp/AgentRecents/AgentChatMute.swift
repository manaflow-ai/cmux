import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon

/// Mute one agent chat's notifications (cx-sg1qz) from its tab's or sidebar
/// row's menu. The mute is the chat's acpmux tag `notifications: muted`, so it
/// lives with the chat: every window, device and the phone feed honor it, and
/// the cmux-tui daemon posts nothing for a muted chat (no banner, no badge).
/// The menu reads it back from the turn-state watch (`AgentTurnStateStore`),
/// so it says Unmute once acpmux has the tag.
@MainActor
struct AgentChatMute {
    let environment: AcpmuxEnvironment
    let turns: AgentTurnStateStore

    /// Whether the chat is muted; nil when it is not a chat of this Mac's acpmux.
    func isMuted(_ chat: AgentSessionRef) -> Bool? { turns.isMuted(chat) }

    /// Mutes the chat, or unmutes a muted one. False when it is not a chat of this Mac's acpmux.
    func toggle(_ chat: AgentSessionRef) async throws -> Bool {
        guard let session = chat.session, let muted = isMuted(chat) else { return false }
        _ = (session, muted)
        return true
    }
}
