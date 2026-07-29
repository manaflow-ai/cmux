import Foundation
import GhosttyKit

extension GhosttyApp {
    func handleAgentSessionCommandFinishedAction(
        tabId: UUID?,
        surfaceId: UUID?,
        message: ghostty_action_command_finished_s
    ) -> Bool {
        let exitCode = message.exit_code >= 0 ? Int(message.exit_code) : nil
        guard let tabId, let surfaceId else { return true }

        Task { @MainActor in
            guard let app = AppDelegate.shared,
                  let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
                return
            }
            tabManager.handleAgentSessionCommandFinished(
                workspaceId: tabId,
                panelId: surfaceId,
                exitCode: exitCode
            )
        }
        return true
    }
}
