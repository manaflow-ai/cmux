import CmuxNextActions
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

    /// The chat a workspace row's summary line shows (SidebarMapping.lastMessage): the front
    /// tab's, else the first started chat's.
    private static func rowChat(_ workspace: WorkspaceModel, services: AppServices) -> String? {
        let panes = workspace.screens.flatMap(\.panes).filter { !$0.tabs.isEmpty }
        if let pane = panes.max(by: { $0.focusedAt < $1.focusedAt }), let id = services.paneController(for: pane)?.selectedTab?.id,
           let front = pane.tabs.first(where: { $0.id == id }), let session = started(front) {
            return session
        }
        return panes.lazy.flatMap(\.tabs).compactMap(started).first
    }
}

/// Handlers.xcstrings.
enum AgentChatIdentifierStrings {
    static var notAChat: String {
        String(localized: "agentChat.copyIdentifier.notAChat", defaultValue: "Only a started agent chat has an identifier to copy.",
               table: "Handlers", bundle: .module)
    }
}
