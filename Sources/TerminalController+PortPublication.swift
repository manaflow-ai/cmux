import AppKit
import Foundation

extension TerminalController {
    func applyPanelPortPublication(workspaceId: UUID, panelId: UUID, ports: [Int]) {
        guard let workspace = portPublicationWorkspace(workspaceId: workspaceId),
              workspace.panels[panelId] != nil else { return }
        let nextPorts: [Int]? = ports.isEmpty ? nil : ports
        guard workspace.surfaceListeningPorts[panelId] != nextPorts else { return }
        if let nextPorts {
            workspace.setSurfaceListeningPorts(nextPorts, for: panelId)
        } else {
            workspace.removeSurfaceListeningPorts(for: panelId)
        }
        workspace.recomputeListeningPorts()
    }

    func applyAgentPortPublication(workspaceId: UUID, ports: [Int]) -> Bool {
        guard let workspace = portPublicationWorkspace(workspaceId: workspaceId) else { return false }
        if workspace.agentListeningPorts != ports {
            workspace.agentListeningPorts = ports
            workspace.recomputeListeningPorts()
        }
        return true
    }

    private func portPublicationWorkspace(workspaceId: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs.first { $0.id == workspaceId }
    }
}
