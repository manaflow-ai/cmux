import Foundation

extension Workspace {
    /// Reconciles previously completed restored agents against the fresh index.
    /// Only their lifecycle state changes; this never publishes the workspace.
    func handleSharedLiveAgentIndexChange(userInfo: [AnyHashable: Any]?) {
        guard !isRetiredFromOwningTabManager else { return }
        if let index = SharedLiveAgentIndex.shared.index {
            let completedPanelIds: [UUID]
            if let panelIdsByWorkspaceId = userInfo?["panelIdsByWorkspaceId"] as? [UUID: Set<UUID>] {
                guard let changedPanelIds = panelIdsByWorkspaceId[self.id] else {
                    return
                }
                completedPanelIds = changedPanelIds.filter { panelId in
                    self.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit
                }
            } else if let changedWorkspaceId = userInfo?["workspaceId"] as? UUID,
                      changedWorkspaceId != self.id {
                return
            } else if let changedPanelId = userInfo?["panelId"] as? UUID {
                completedPanelIds = self.restoredAgentResumeStatesByPanelId[changedPanelId] == .completedAgentExit
                    ? [changedPanelId]
                    : []
            } else {
                completedPanelIds = self.restoredAgentResumeStatesByPanelId.compactMap { panelId, state in
                    state == .completedAgentExit ? panelId : nil
                }
            }
            for panelId in completedPanelIds {
                guard let observation = index.entry(workspaceId: self.id, panelId: panelId) else {
                    continue
                }
                self.reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
            }
        }
    }
}
