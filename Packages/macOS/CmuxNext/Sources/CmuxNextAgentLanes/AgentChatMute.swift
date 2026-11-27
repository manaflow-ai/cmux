public import CmuxNextAgentPane
public import CmuxNextBridge
public import CmuxNextDaemon
import Foundation

/// Mute one agent chat's notifications (cx-sg1qz) from its tab's or sidebar
/// row's menu. The mute is the chat's acpmux tag `notifications: muted`, so it
/// lives with the chat: every window, device and the phone feed honor it, and
/// the cmux-tui daemon posts nothing for a muted chat (no banner, no badge).
/// The menu reads it back from the turn-state watch (`AgentTurnStateStore`),
/// so it says Unmute once acpmux has the tag.
@MainActor
public struct AgentChatMute {
    public let environment: AcpmuxEnvironment
    public let turns: AgentTurnStateStore

    public init(environment: AcpmuxEnvironment, turns: AgentTurnStateStore) {
        self.environment = environment
        self.turns = turns
    }

    /// Whether the chat is muted; nil when it is not a chat of this Mac's acpmux.
    public func isMuted(_ chat: AgentSessionRef) -> Bool? { turns.isMuted(chat) }

    /// Mutes the chat, or unmutes a muted one. False when it is not a chat of this Mac's acpmux.
    public func toggle(_ chat: AgentSessionRef) async throws -> Bool {
        guard let session = chat.session, let muted = isMuted(chat) else { return false }
        let tag = AgentTurnStates.muteTag
        try await environment.tag(session: session, set: muted ? [:] : [tag: AgentTurnStates.mutedValue],
                                  remove: muted ? [tag] : [])
        return true
    }
}

/// The mute rows' strings (Localizable.xcstrings).
public struct AgentChatMuteStrings {
    public init() {}
    public static var mute: String {
        String(localized: "agentChat.muteNotifications", defaultValue: "Mute Chat Notifications", bundle: .localizedModule)
    }
    public static var unmute: String {
        String(localized: "agentChat.unmuteNotifications", defaultValue: "Unmute Chat Notifications", bundle: .localizedModule)
    }
    public static var notAChat: String {
        String(localized: "agentChat.mute.notAChat", defaultValue: "Only an agent chat on this Mac can be muted.", bundle: .localizedModule)
    }
    public static var failed: String {
        String(localized: "agentChat.mute.failed", defaultValue: "The chat's notifications could not be changed.", bundle: .localizedModule)
    }
}
