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
        for panel in panels.values { panel.close() }
        panels.removeAll()
        surfaceIdToPanelId.removeAll()
        detachedSurfaceTransfersByPanelId.removeAll()
        restoredTerminalScrollbackByPanelId.removeAll()
        restoredAgentLifecycle.snapshotsByPanelId.removeAll()
        restoredAgentLifecycle.resumeStatesByPanelId.removeAll()
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeAll()
        surfaceResumeBindingsByPanelId.removeAll()
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
