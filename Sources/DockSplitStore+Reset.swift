import Bonsplit

extension DockSplitStore {
    func removeAllPanels() {
        let tabIds = Set(bonsplitController.allTabIds)
        pendingCloseConfirmDockTabIds.removeAll()
        tabCloseButtonCloseDockTabIds.removeAll()
        forceCloseDockTabIds.formUnion(tabIds)
        defer { forceCloseDockTabIds.subtract(tabIds) }
        for tabId in tabIds { _ = bonsplitController.closeTab(tabId) }
        collapseToSingleEmptyPane()
        reconcilePanels()
        surfaceIdToPanelId.removeAll()
        for panelId in Array(panels.keys) {
            discardPanelStateAndClose(panelId: panelId)
        }
        removeAllDetachedSurfaceTransfers()
        agentRuntimeByPanelId.removeAll()
        restoredTerminalScrollbackByPanelId.removeAll()
        restoredAgentLifecycle.snapshotsByPanelId.removeAll()
        restoredAgentLifecycle.resumeStatesByPanelId.removeAll()
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeAll()
        surfaceResumeBindingsByPanelId.removeAll()
        unresolvedResumeBindingPanelIds.removeAll()
        managedAgentResumeBindingsByPanelId.removeAll()
        invalidatedCachedTransferAgentSessionPanelIds.removeAll()
        replacedCachedTransferAgentSessionPanelIds.removeAll()
        restoredResumeSessionWorkingDirectoriesByPanelId.removeAll()
        panelCancellables.values.forEach { $0.cancel() }
        panelCancellables.removeAll()
    }

    func cancelConfigurationTasks() {
        configurationLoadGeneration += 1
        configurationIdentityGeneration += 1
        configurationLoadTask?.cancel()
        configurationIdentityTask?.cancel()
        configurationLoadTask = nil
        configurationIdentityTask = nil
        configurationLoadRootDirectory = nil
    }
}
