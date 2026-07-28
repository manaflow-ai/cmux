import Foundation

extension TabManager {
    func handleAgentSessionCommandFinished(
        workspaceId: UUID,
        panelId: UUID,
        exitCode: Int?
    ) {
        guard let workspace = workspacesById[workspaceId],
              workspace.panels[panelId] is TerminalPanel else {
            return
        }
        workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: panelId,
            exitCode: exitCode
        )
    }
}
