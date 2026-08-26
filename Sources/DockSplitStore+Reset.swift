import Bonsplit

extension DockSplitStore {
    func removeAllPanels() {
        cancelDockReactGrabTask()
        let tabIds = Set(bonsplitController.allTabIds)
        pendingCloseConfirmDockTabIds.removeAll()
        tabCloseButtonCloseDockTabIds.removeAll()
        closeHistoryEligibleDockTabIds.removeAll()
        pendingClosedPanelHistoryEntries.removeAll()
        pendingClosedPaneHistoryEntries.removeAll()
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
        agentRuntimePanelIDByPIDKey.removeAll()
        restoredTerminalScrollbackByPanelId.removeAll()
        restoredAgentLifecycle.snapshotsByPanelId.removeAll()
        restoredAgentLifecycle.resumeStatesByPanelId.removeAll()
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeAll()
        surfaceResumeBindingsByPanelId.removeAll()
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
