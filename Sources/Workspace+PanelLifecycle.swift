import Bonsplit
import Darwin
import Foundation

extension Workspace {
    enum AgentPIDExitWatcherScope: Equatable {
        case panel(UUID)
        case unscoped

        init(panelId: UUID?) {
            if let panelId {
                self = .panel(panelId)
            } else {
                self = .unscoped
            }
        }

        var panelId: UUID? {
            switch self {
            case .panel(let id):
                id
            case .unscoped:
                nil
            }
        }
    }

    private static let agentPIDExitWatcherQueue = DispatchQueue(
        label: "com.cmux.sidebar-agent-pid-exit",
        qos: .utility
    )

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []

        var agentPIDsForPanel: [String: pid_t] = [:]
        var agentProcessStatesForPanel: [String: SidebarAgentProcessState] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
            }
            if let processState = agentProcessStates[key] {
                agentProcessStatesForPanel[key] = processState
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty || !agentPIDsForPanel.isEmpty || !agentProcessStatesForPanel.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentProcessStates: agentProcessStatesForPanel,
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

    private func armAgentPIDExitWatcher(key: String, pid: pid_t, panelId: UUID?) {
        let scope = AgentPIDExitWatcherScope(panelId: panelId)
        if agentPIDExitWatchers[key] != nil,
           agentPIDExitWatcherPIDs[key] == pid,
           agentPIDExitWatcherScopes[key] == scope {
            return
        }
        agentPIDExitWatchers.removeValue(forKey: key)?.cancel()
        agentPIDExitWatcherPIDs.removeValue(forKey: key)
        agentPIDExitWatcherScopes.removeValue(forKey: key)
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: Self.agentPIDExitWatcherQueue
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentPIDs[key] == pid else { return }
                _ = self.clearAgentPID(key: key, panelId: scope.panelId, clearStatus: true)
            }
        }
        agentPIDExitWatchers[key] = source
        agentPIDExitWatcherPIDs[key] = pid
        agentPIDExitWatcherScopes[key] = scope
        source.resume()
    }

    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) {
        guard pid > 0 else {
            _ = clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: refreshPorts)
            return
        }

        setAgentPIDStorageValue(pid, forKey: key)
        if let panelId {
            recordAgentPIDOwnership(key: key, panelId: panelId)
        } else {
            removeAgentPIDOwnership(key: key)
        }
        armAgentPIDExitWatcher(key: key, pid: pid, panelId: panelId)
        if agentProcessStates[key]?.pid != pid || agentProcessStates[key]?.isAlive != true {
            setAgentProcessStateStorageValue(SidebarAgentProcessState(
                pid: pid,
                isAlive: true,
                activity: .running
            ), forKey: key)
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
        setAgentProcessStateStorageValue(state, forKey: key)
        return true
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        clearNotifications: Bool = true,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let effectivePanelId = panelId ?? ownedPanelId
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil

        var didChange = false
        var removedRuntime = false
        if removeAgentPIDStorageValue(forKey: key) != nil {
            didChange = true
            removedRuntime = true
        }
        if removeAgentProcessStateStorageValue(forKey: key) != nil {
            didChange = true
            removedRuntime = true
        }
        if let watcher = agentPIDExitWatchers.removeValue(forKey: key) {
            watcher.cancel()
            didChange = true
        }
        if agentPIDExitWatcherPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDExitWatcherScopes.removeValue(forKey: key) != nil {
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
        if clearStatus, clearNotifications, didChange, let effectivePanelId {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: effectivePanelId)
        } else if clearStatus, clearNotifications, didChange, removedRuntime {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id)
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
            .union(agentPIDExitWatchers.keys)
            .union(agentPIDExitWatcherPIDs.keys)
            .union(agentPIDExitWatcherScopes.keys)
        for key in keys {
            _ = clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
        }
        agentListeningPorts.removeAll()
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    @discardableResult
    func clearSidebarMetadataEntry(key: String, refreshPorts: Bool = true) -> Bool {
        let didClearRuntime = clearAgentPID(
            key: key,
            clearStatus: true,
            refreshPorts: refreshPorts
        )
        if statusEntries.removeValue(forKey: key) != nil {
            return true
        }
        return didClearRuntime
    }

    @discardableResult
    private func discardAgentRuntimeState(
        _ runtimeState: DetachedAgentRuntimeState?,
        clearNotifications: Bool = true
    ) -> Bool {
        guard let runtimeState else { return false }
        var didChange = false
        for key in runtimeState.agentPIDKeys {
            if clearAgentPID(
                key: key,
                panelId: runtimeState.panelId,
                clearStatus: true,
                clearNotifications: clearNotifications,
                refreshPorts: false
            ) {
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
            if let processState = runtimeState.agentProcessStates[key],
               processState.pid == pid {
                setAgentProcessStateStorageValue(processState, forKey: key)
            }
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
        requestTransferredRemoteCleanup: Bool,
        cleanupControllerSurfaceState: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId, tabId?.uuid].compactMap { $0 })
        }
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
        discardAgentRuntimeState(closedAgentRuntimeState, clearNotifications: clearSurfaceNotifications)
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
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
