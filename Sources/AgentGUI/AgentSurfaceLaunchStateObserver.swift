import CMUXAgentLaunch
import Foundation

@MainActor
final class AgentSurfaceLaunchStateObserver: AgentLaunchObserving {
    private let service: AgentGUIService

    init(service: AgentGUIService) {
        self.service = service
    }

    func agentLaunchState(surfaceID: String) -> AgentLaunchSurfaceState {
        if let snapshot = service.sessionSnapshot(surfaceID: surfaceID) {
            if snapshot.phase != .ended {
                return .runningAgent
            }
            if foregroundAgentIsRunning(surfaceID: surfaceID) {
                return .runningAgent
            }
            return .endedAgent
        }
        return foregroundAgentIsRunning(surfaceID: surfaceID) ? .runningAgent : .idleShell
    }

    func agentLaunchObservationGeneration(surfaceID: String) -> UInt64 {
        service.completedProcessObservationGeneration
    }

    func requestAgentLaunchObservation(surfaceID: String) -> UInt64 {
        service.requestPostLaunchProcessScan()
    }

    private func foregroundAgentIsRunning(surfaceID: String) -> Bool {
        guard let surfaceUUID = UUID(uuidString: surfaceID),
              let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceUUID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let panel = workspace.terminalPanel(for: surfaceUUID) else {
            return false
        }
        let context = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        return TextBoxAgentDetection.supportsActiveAgentPrefixes(context: context)
    }
}
