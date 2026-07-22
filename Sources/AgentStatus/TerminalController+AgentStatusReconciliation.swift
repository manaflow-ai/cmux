import CMUXAgentLaunch
import Foundation

extension TerminalController {
    nonisolated func noteAgentStatusHookEvent(_ event: WorkstreamEvent) {
        guard let signal = AgentStatusHookEventSignal(event: event) else { return }
        let resolved = FeedCoordinator.resolveAttentionTarget(event: event)
        Task { @MainActor in
            guard let workspaceId = resolved?.workspaceId,
                  let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  let panelId = FeedCoordinator.resolvePanelId(
                      surfaceId: resolved?.surfaceId,
                      tab: workspace
                  ) else {
                return
            }
            workspace.noteAgentStatusHookSignal(signal, panelId: panelId)
        }
    }
}
