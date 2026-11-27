import CmuxControlSocket
import Foundation

extension TerminalController {
    @MainActor
    @discardableResult
    func presentAgentRestoreRecovery(
        workspaceID: UUID,
        surfaceID: UUID,
        state: AgentRestoreRecoveryPresentation.State?
    ) -> Bool {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: workspaceID, surfaceID: surfaceID, paneID: nil
        )
        guard let manager = resolveTabManager(routing: routing) else { return false }
        let dockPanel = windowDockForRouting(routing, tabManager: manager)?.panels[surfaceID] as? TerminalPanel
        let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: manager)
        let panel = dockPanel ?? workspace?.terminalInputTarget(forPanelID: surfaceID)?.panel
        guard let panel, panel.restoreRecovery.state != state else { return false }
        panel.restoreRecovery.state = state
        return true
    }
}
