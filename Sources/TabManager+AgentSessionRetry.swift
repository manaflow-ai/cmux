import Foundation

extension TabManager {
    func handleAgentSessionCommandFinished(
        workspaceId: UUID,
        panelId: UUID,
        exitCode: Int?
    ) {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] is TerminalPanel else {
            return
        }
        workspace.agentSessionRetryCoordinator.commandFinished(
            panelId: panelId,
            exitCode: exitCode
        )
    }
}
