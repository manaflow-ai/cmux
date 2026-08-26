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
        removeAllSurfaceMappings()
        for panelId in Array(panels.keys) {
            discardPanelStateAndClose(panelId: panelId)
        }
        removeAllDetachedSurfaceTransfers()
        agentRuntimeByPanelId.removeAll()
        agentRuntimePanelIDByPIDKey.removeAll()
        agentNeedsInputAttention.replace(with: [])
        restoredTerminalScrollbackByPanelId.removeAll()
        terminalStartupRestoreCoordinator.removeAllRestores()
        clearDeferredAgentResumeRestores()
        surfaceResumeBindingsByPanelId.removeAll()
        managedAgentResumeBindingsByPanelId.removeAll()
        invalidatedCachedTransferAgentSessionPanelIds.removeAll()
        replacedCachedTransferAgentSessionPanelIds.removeAll()
        manualUnreadPanelIds.removeAll()
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
