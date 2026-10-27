import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Mute Chat Notifications (cx-sg1qz) on an agent chat tab and its sidebar
/// row: the chat's acpmux tag (`AgentChatMute`). The row reads Mute or
/// Unmute for the right-clicked chat and is left out of other tabs' menus.
enum AgentChatMuteHandlers {
    static let action: ActionID = "agentChat.toggleNotificationMute"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        /// The targeted tab's chat, when it is one of this Mac's acpmux.
        let chat = { (invocation: ActionInvocation) -> (AgentChatMute, AgentSessionRef, muted: Bool)? in
            guard let muting = mute(services), let chat = context.daemonTab(invocation)?.tab.agentSession,
                  let muted = muting.isMuted(chat) else { return nil }
            return (muting, chat, muted)
        }
        registry.bind(action, invoke: { invocation in
            guard let (_, session, _) = chat(invocation) else { return context.refuse(AgentChatMuteStrings.notAChat) }
            // The tag write is awaited off the action's turn; its outcome is one task of the run's completion.
            registry.trackWork(owner: "AgentChatMuteHandlers.toggle", on: services.mainWork) {
                try await toggle(session, services: services)
            } then: { result in
                guard case .failure = result else { return nil }
                return ActionWorkFailure(AgentChatMuteStrings.failed)
            }
        })
        ActionTargetTitles.set(action, in: registry) { invocation in
            guard let (_, _, muted) = chat(invocation) else { return nil }
            return muted ? AgentChatMuteStrings.unmute : AgentChatMuteStrings.mute
        }
        ActionTargetVisibility.hide(action, in: registry) { invocation in
            invocation.target?.kind == .tab && chat(invocation) == nil
        }
    }

    /// This Mac's acpmux chat mute, or nil without an acpmux.
    private static func mute(_ services: AppServices) -> AgentChatMute? {
        QuitAgents.environment(services).map { AgentChatMute(environment: $0, turns: .shared) }
    }

    /// Mutes `session`'s chat, or unmutes a muted one (nothing without an acpmux).
    private static func toggle(_ session: AgentSessionRef, services: AppServices) async throws {
        _ = try await mute(services)?.toggle(session)
    }
}

/// Handlers.xcstrings.
enum AgentChatMuteStrings {
    static var mute: String {
        String(localized: "agentChat.muteNotifications", defaultValue: "Mute Chat Notifications", table: "Handlers", bundle: .module)
    }
    static var unmute: String {
        String(localized: "agentChat.unmuteNotifications", defaultValue: "Unmute Chat Notifications", table: "Handlers", bundle: .module)
    }
    static var notAChat: String {
        String(localized: "agentChat.mute.notAChat", defaultValue: "Only an agent chat on this Mac can be muted.",
               table: "Handlers", bundle: .module)
    }
    static var failed: String {
        String(localized: "agentChat.mute.failed", defaultValue: "The chat's notifications could not be changed.",
               table: "Handlers", bundle: .module)
    }
}
