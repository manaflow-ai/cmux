import CmuxNextActions
import Foundation

/// Copy Agent Identifier (cx-s7004) on an agent chat's tab, its sidebar row,
/// the chat itself and the palette: the chat's acpmux session id, the id
/// cross-session messaging takes (`acpmux send <id>`, `cmux agent message <id>`).
/// Left out of the menus of other tabs and of a new chat that has no session yet.
enum AgentChatIdentifierHandlers {
    static let action: ActionID = "agentChat.copyIdentifier"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let session = { (invocation: ActionInvocation) -> String? in
            context.daemonTab(invocation)?.tab.agentSession?.session.flatMap { $0.isEmpty ? nil : $0 }
        }
        registry.bind(action, invoke: { invocation in
            guard let id = session(invocation) else { return context.refuse(AgentChatIdentifierStrings.notAChat) }
            context.copy(id)
        })
        ActionTargetVisibility.hide(action, in: registry) { invocation in
            invocation.target?.kind == .tab && session(invocation) == nil
        }
    }
}

/// Handlers.xcstrings.
enum AgentChatIdentifierStrings {
    static var notAChat: String {
        String(localized: "agentChat.copyIdentifier.notAChat", defaultValue: "Only a started agent chat has an identifier to copy.",
               table: "Handlers", bundle: .module)
    }
}
