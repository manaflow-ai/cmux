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
        let mute = { QuitAgents.environment(context.services).map { AgentChatMute(environment: $0, turns: .shared) } }
        /// The targeted tab's chat, when it is one of this Mac's acpmux.
        let chat = { (invocation: ActionInvocation) -> (AgentChatMute, AgentSessionRef, muted: Bool)? in
            guard let mute = mute(), let chat = context.daemonTab(invocation)?.tab.agentSession,
                  let muted = mute.isMuted(chat) else { return nil }
            return (mute, chat, muted)
        }
        registry.bind(action, invoke: { invocation in
            guard let (mute, session, _) = chat(invocation) else { return context.refuse(AgentChatMuteStrings.notAChat) }
            registry.track(Task { @MainActor in
                do {
                    _ = try await mute.toggle(session)
                    return nil
                } catch {
                    return ActionWorkFailure(AgentChatMuteStrings.failed)
                }
            })
        })
        ActionTargetTitles.setState(action, in: registry) { invocation in chat(invocation)?.muted }
        ActionTargetVisibility.hide(action, in: registry) { invocation in
            invocation.target?.kind == .tab && chat(invocation) == nil
        }
    }
}

/// Handlers.xcstrings.
enum AgentChatMuteStrings {
    static var notAChat: String {
        String(localized: "agentChat.mute.notAChat", defaultValue: "Only an agent chat on this Mac can be muted.",
               table: "Handlers", bundle: .module)
    }
    static var failed: String {
        String(localized: "agentChat.mute.failed", defaultValue: "The chat's notifications could not be changed.",
               table: "Handlers", bundle: .module)
    }
}
