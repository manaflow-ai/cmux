import CMUXAgentLaunch
import Foundation

extension TerminalController {
    nonisolated func noteAgentStatusHookEvent(_ event: WorkstreamEvent) {
        guard let signal = AgentStatusHookEventSignal(event: event) else { return }
        let resolved = FeedCoordinator.resolveAttentionTarget(event: event)
        Task { @MainActor in
            guard let resolved,
                  let liveTarget = AppDelegate.shared?.agentNotificationDeliveryTarget(
                      claimedTabId: resolved.workspaceId,
                      surfaceId: resolved.surfaceId
                  ),
                  let surfaceId = liveTarget.surfaceId,
                  let tabManager = AppDelegate.shared?.tabManagerFor(tabId: liveTarget.tabId),
                  let workspace = tabManager.tabs.first(where: { $0.id == liveTarget.tabId }),
                  let panelId = FeedCoordinator.resolvePanelId(
                      surfaceId: surfaceId,
                      tab: workspace
                  ) else {
                return
            }
            workspace.noteAgentStatusHookSignal(signal, panelId: panelId)
        }
    }
}
