import AppKit
import CmuxMobileHost
import Foundation

/// Shared action path for the sidebar session rows, the `jumpToLastPrompt`
/// shortcut, and `cmux jump-to-last-prompt`: locate an agent session's pane
/// and focus it through the notification-open path (no selection flash).
@MainActor
extension AppDelegate {
    struct ResolvedAgentSession {
        let record: AgentChatSessionRecord
        let panelId: UUID
        let workspace: Workspace
        let tabManager: TabManager
    }

    /// The most recently typed-into live session whose pane still exists in
    /// some window. Records are ordered by their last hook prompt; the first
    /// whose pane resolves wins. The record's stored workspace id is only a
    /// hint (it goes stale across relaunches), the pane binding is authoritative.
    func resolvedLastTypedAgentSession() -> ResolvedAgentSession? {
        guard let service = TerminalController.shared.agentChatTranscriptService else { return nil }
        for record in service.lastTypedLiveSessions() {
            guard let panelId = record.surfaceID.flatMap(UUID.init(uuidString:)) else { continue }
            let preferredWorkspaceId = record.workspaceID.flatMap(UUID.init(uuidString:))
            guard let located = workspaceContainingPanel(panelId: panelId, preferredWorkspaceId: preferredWorkspaceId) else {
                continue
            }
            return ResolvedAgentSession(
                record: record,
                panelId: panelId,
                workspace: located.workspace,
                tabManager: located.tabManager
            )
        }
        return nil
    }

    /// Selects the pane's workspace and focuses the pane, across windows.
    /// Returns false when no workspace owns the pane.
    @discardableResult
    func focusAgentSurface(panelId: UUID, preferredWorkspaceId: UUID?) -> Bool {
        guard let located = workspaceContainingPanel(panelId: panelId, preferredWorkspaceId: preferredWorkspaceId) else {
            return false
        }
        return focusTerminal(tabId: located.workspace.id, surfaceId: panelId)
    }
}
