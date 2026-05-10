import Bonsplit
import Darwin
import Foundation

extension Workspace {
    private static let agentPIDExitWatcherQueue = DispatchQueue(
        label: "com.cmux.sidebar-agent-pid-exit",
        qos: .utility
    )

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []

        var agentPIDsForPanel: [String: pid_t] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty || !agentPIDsForPanel.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDKeys: pidKeys
        )
    }

    func agentStatusKey(forAgentPIDKey key: String) -> String {
        if statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    private func hasAgentRuntime(forStatusKey statusKey: String) -> Bool {
        for key in agentPIDs.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentProcessStates.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentPIDPanelIdsByKey.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        return false
    }

    private func removeAgentPIDOwnership(key: String) {
        if let previousPanelId = agentPIDPanelIdsByKey[key] {
            agentPIDKeysByPanelId[previousPanelId]?.remove(key)
            if agentPIDKeysByPanelId[previousPanelId]?.isEmpty == true {
                agentPIDKeysByPanelId.removeValue(forKey: previousPanelId)
            }
            agentPIDPanelIdsByKey.removeValue(forKey: key)
        }
    }

    private func recordAgentPIDOwnership(key: String, panelId: UUID) {
        if let previousPanelId = agentPIDPanelIdsByKey[key], previousPanelId != panelId {
            removeAgentPIDOwnership(key: key)
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    private func armAgentPIDExitWatcher(key: String, pid: pid_t) {
        if agentPIDExitWatchers[key] != nil, agentPIDs[key] == pid {
            return
        }
        agentPIDExitWatchers.removeValue(forKey: key)?.cancel()
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: Self.agentPIDExitWatcherQueue
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentPIDs[key] == pid else { return }
                _ = self.clearAgentPID(key: key, clearStatus: true)
            }
        }
        agentPIDExitWatchers[key] = source
        source.resume()
    }

    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) {
        guard pid > 0 else {
            _ = clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: refreshPorts)
            return
        }

        let existingPID = agentPIDs[key]
        agentPIDs[key] = pid
        armAgentPIDExitWatcher(key: key, pid: pid)
        if let panelId {
            recordAgentPIDOwnership(key: key, panelId: panelId)
        } else if existingPID != pid {
            removeAgentPIDOwnership(key: key)
        }
        if agentProcessStates[key]?.pid != pid || agentProcessStates[key]?.isAlive != true {
            agentProcessStates[key] = SidebarAgentProcessState(
                pid: pid,
                isAlive: true,
                activity: .running
            )
        }
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    func setAgentPID(
        key: String,
        panelId: UUID? = nil,
        pid: pid_t,
        refreshPorts: Bool = true
    ) {
        recordAgentPID(key: key, pid: pid, panelId: panelId, refreshPorts: refreshPorts)
    }

    @discardableResult
    func updateAgentProcessState(key: String, state: SidebarAgentProcessState) -> Bool {
        guard agentPIDs[key] == state.pid else { return false }
        guard agentProcessStates[key] != state else { return false }
        agentProcessStates[key] = state
        return true
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let effectivePanelId = panelId ?? ownedPanelId
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentProcessStates.removeValue(forKey: key) != nil {
            didChange = true
        }
        if let watcher = agentPIDExitWatchers.removeValue(forKey: key) {
            watcher.cancel()
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, let effectivePanelId {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: effectivePanelId)
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func refreshTrackedAgentPorts() {
        agentListeningPorts.removeAll(keepingCapacity: false)
        let remainingAgentPIDs = Set(agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
        PortScanner.shared.refreshAgentPorts(workspaceId: id, agentPIDs: remainingAgentPIDs)
        recomputeListeningPorts()
    }

    func clearAllAgentRuntimeState(refreshPorts: Bool = true) {
        let keys = Set(agentPIDs.keys)
            .union(agentProcessStates.keys)
            .union(agentPIDPanelIdsByKey.keys)
        for key in keys {
            _ = clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
        }
        agentPIDKeysByPanelId.removeAll()
        for watcher in agentPIDExitWatchers.values {
            watcher.cancel()
        }
        agentPIDExitWatchers.removeAll()
        agentListeningPorts.removeAll()
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    @discardableResult
    private func discardAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(key: key, panelId: runtimeState.panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func adoptDetachedAgentRuntimeState(_ runtimeState: DetachedAgentRuntimeState?) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs {
            recordAgentPID(key: key, pid: pid, panelId: runtimeState.panelId, refreshPorts: false)
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        if didAdoptAgentPID {
            refreshTrackedAgentPorts()
        }
    }

    /// Discard every Workspace-owned contribution for a surface whose tab,
    /// pane, or workspace has already been accepted for closure.
    @discardableResult
    func discardClosedPanelLifecycleState(
        panelId: UUID,
        tabId: TabID? = nil,
        paneId: PaneID?,
        panel: (any Panel)?,
        origin: String,
        closePanel: Bool,
        publishSurfaceClosedEvent: Bool,
        clearSurfaceNotifications: Bool,
        requestTransferredRemoteCleanup: Bool
    ) -> WorkspaceRemoteConfiguration? {
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if closePanel {
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        if let tabId {
            surfaceIdToPanelId.removeValue(forKey: tabId)
        } else {
            surfaceIdToPanelId = surfaceIdToPanelId.filter { $0.value != panelId }
        }

        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentAutoResumePendingPanelIds.remove(panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        if clearSurfaceNotifications {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }

        if requestTransferredRemoteCleanup, let transferredRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        return transferredRemoteCleanupConfiguration
    }
}
