import CmuxNextActions
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextDaemon
import Foundation

/// Copy Agent Identifier (cx-s7004) on an agent chat's tab, its sidebar row,
/// the chat itself, the sidebar workspace row that shows its summary and the
/// palette: the chat's acpmux session id, the id cross-session messaging takes
/// (`acpmux send <id>`, `cmux agent message <id>`). Left out of the menus of
/// other tabs, of a new chat that has no session yet and of a workspace with no chat.
enum AgentChatIdentifierHandlers {
    static let action: ActionID = "agentChat.copyIdentifier"

    /// `copy` writes the id (default the general pasteboard, `context.copy`).
    static func bind(into registry: ActionRegistry, context: AppActionContext, copy: (@MainActor (String) -> Void)? = nil) {
        let session = { (invocation: ActionInvocation) -> String? in
            if invocation.target?.kind == .workspace {
                return context.scope(invocation).workspace.flatMap { rowChat($0, services: context.services) }
            }
            return context.daemonTab(invocation).flatMap { started($0.tab) }
        }
        registry.bind(action, invoke: { invocation in
            guard let id = session(invocation) else { return context.refuse(AgentChatIdentifierStrings.notAChat) }
            (copy ?? context.copy)(id)
        })
        ActionTargetVisibility.hide(action, in: registry) { invocation in
            (invocation.target?.kind == .tab || invocation.target?.kind == .workspace) && session(invocation) == nil
        }
    }

    private static func started(_ tab: TabModel) -> String? {
        tab.agentSession?.session.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The chat a workspace row's summary line shows (SidebarMapping), by the active window's
    /// tab selection as the sidebar reads it.
    private static func rowChat(_ workspace: WorkspaceModel, services: AppServices) -> String? {
        let selection = services.windows.active?.state.selection
        return SidebarMapping.shared.rowChat(workspace, selectedTab: { selection?.selection(in: $0.id) }).flatMap(started)
    }
}

/// Handlers.xcstrings.
enum AgentChatIdentifierStrings {
    static var notAChat: String {
        String(localized: "agentChat.copyIdentifier.notAChat", defaultValue: "Only a started agent chat has an identifier to copy.",
               table: "Handlers", bundle: .module)
    }
}
