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
        agentNeedsInputAttention.replace(with: [])
        restoredTerminalScrollbackByPanelId.removeAll()
        terminalStartupRestoreCoordinator.removeAllRestores()
        clearDeferredAgentResumeRestores()
        surfaceResumeBindingsByPanelId.removeAll()
        surfaceResumeRestoreClaimsByPanelId.removeAll()
        managedAgentResumeBindingsByPanelId.removeAll()
        invalidatedCachedTransferAgentSessionPanelIds.removeAll()
        replacedCachedTransferAgentSessionPanelIds.removeAll()
        manualUnreadPanelIds.removeAll()
        panelCancellables.values.forEach { $0.cancel() }
        panelCancellables.removeAll()
        // Closing the final tab can leave Bonsplit without a selection callback
        // (and therefore without a capability refresh). Publish the empty
        // snapshot explicitly so menu validation cannot retain stale Dock
        // capabilities while a replacement/configuration load is in flight.
        refreshDockMenuCapabilities()
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
