import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import Foundation
import CmuxSidebar

extension Workspace {
    static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    private static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    private static let truthyStartupEnvironmentValues: Set<String> = ["1", "true", "yes", "on", "enabled"]

    var agentPIDs: [String: pid_t] {
        get { sidebarAgentRuntimeObservation.agentPIDs }
        set { sidebarAgentRuntimeObservation.setAgentPIDs(newValue) }
    }

    var agentPIDProcessIdentitiesByKey: [String: AgentPIDProcessIdentity] {
        get { sidebarAgentRuntimeObservation.agentPIDProcessIdentitiesByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDProcessIdentitiesByKey(newValue) }
    }

    var agentPIDPanelIdsByKey: [String: UUID] {
        get { sidebarAgentRuntimeObservation.agentPIDPanelIdsByKey }
        set { sidebarAgentRuntimeObservation.setAgentPIDPanelIdsByKey(newValue) }
    }

    var agentPIDKeysByPanelId: [UUID: Set<String>] {
        get { sidebarAgentRuntimeObservation.agentPIDKeysByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentPIDKeysByPanelId(newValue) }
    }

    var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] {
        get { sidebarAgentRuntimeObservation.agentLifecycleStatesByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentLifecycleStatesByPanelId(newValue) }
    }

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []

        var agentPIDsForPanel: [String: pid_t] = [:]
        var agentPIDIdentitiesForPanel: [String: AgentPIDProcessIdentity] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
                agentPIDIdentitiesForPanel[key] = agentPIDProcessIdentitiesByKey[key]
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntriesByPanelId[panelId]?[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            } else if panelsOwningAgentStatusKey(statusKey).isSubset(of: [panelId]),
                      let statusEntry = statusEntries[statusKey] {
                // The workspace-level slot is last-write-wins across panes, so
                // only attribute it to this panel when no other pane can own
                // the key; otherwise a transferred pane would adopt a sibling
                // agent's status text as its own.
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        for (statusKey, statusEntry) in statusEntriesByPanelId[panelId] ?? [:]
        where statusEntriesForPanel[statusKey] == nil {
            statusEntriesForPanel[statusKey] = statusEntry
        }
        guard !statusEntriesForPanel.isEmpty || !agentPIDsForPanel.isEmpty || !pidKeys.isEmpty else { return nil }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDProcessIdentities: agentPIDIdentitiesForPanel,
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
        if isStructuredAgentHookPIDKey(key) {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key &&
                isStructuredAgentHookPIDKey($0) &&
                agentStatusKey(forAgentPIDKey: $0) != statusKey
            } ?? []
            for staleKey in stalePanelKeys {
                _ = clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false)
            }
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    @discardableResult
    private func clearOtherStructuredAgentRuntimes(onPanel panelId: UUID, keeping retainedKey: String) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        return didChange
    }

    @discardableResult
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) -> Bool {
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(onPanel: panelId, keeping: key)
        }
        agentPIDs[key] = pid
        agentPIDProcessIdentitiesByKey[key] = Self.agentPIDProcessIdentity(pid: pid)
        if let panelId {
            recordAgentPIDOwnership(key: key, panelId: panelId)
        } else {
            removeAgentPIDOwnership(key: key)
        }
        if refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didClearOtherStructuredAgentRuntime
    }

    @discardableResult
    func clearStaleAgentPIDs(refreshPorts: Bool = true) -> Bool {
        var didChange = false
        for (key, pid) in agentPIDs where !isRecordedAgentPIDLive(key: key, pid: pid) {
            if clearAgentPID(key: key, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    @discardableResult
    func clearStaleAgentPIDs(panelId: UUID, refreshPorts: Bool = true) -> Bool {
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for key in keys {
            guard let pid = agentPIDs[key] else {
                if clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                    didChange = true
                }
                continue
            }
            if !isRecordedAgentPIDLive(key: key, pid: pid),
               clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    func clearAllAgentPIDs(refreshPorts: Bool = true) {
        let hadAgentPIDs = !agentPIDs.isEmpty
        agentPIDs.removeAll()
        agentPIDProcessIdentitiesByKey.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        statusEntriesByPanelId.removeAll()
        if hadAgentPIDs, refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    private func isRecordedAgentPIDLive(key: String, pid: pid_t) -> Bool {
        guard pid > 0,
              let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
              let currentIdentity = Self.agentPIDProcessIdentity(pid: pid) else {
            return false
        }
        return currentIdentity == recordedIdentity
    }

    static func agentPIDProcessIdentity(pid: pid_t) -> AgentPIDProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return AgentPIDProcessIdentity(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else {
            return false
        }

        if AgentIntegrationSettingsStore(defaults: .standard).suppressesSubagentNotifications,
           terminalPanelHasManagedSubagentStartupEnvironment(panelId: panelId) {
            return true
        }

        let panelKeys = agentPIDKeysByPanelId[panelId] ?? []
        return panelKeys.contains { isStructuredAgentHookPIDKey($0) }
    }

    private func terminalPanelHasManagedSubagentStartupEnvironment(panelId: UUID) -> Bool {
        guard let rawValue = terminalPanel(for: panelId)?
            .surface
            .startupEnvironmentValue(Self.managedSubagentEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return Self.truthyStartupEnvironmentValues.contains(rawValue)
    }

    private func isStructuredAgentHookPIDKey(_ key: String) -> Bool {
        Self.structuredAgentHookStatusKeys.contains(agentStatusKey(forAgentPIDKey: key))
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
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDProcessIdentitiesByKey.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let lifecyclePanelId = ownedPanelId ?? panelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            if clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
                didChange = true
            }
            if let statusKeyToClear, clearPanelStatusEntry(statusKey: statusKeyToClear, panelId: lifecyclePanelId) {
                didChange = true
            }
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
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
            recordPanelStatusEntry(statusEntry, panelId: runtimeState.panelId)
        }
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs {
            recordAgentPID(key: key, pid: pid, panelId: runtimeState.panelId, refreshPorts: false)
            if let recordedIdentity = runtimeState.agentPIDProcessIdentities[key] {
                agentPIDProcessIdentitiesByKey[key] = recordedIdentity
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
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        discardBrowserPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId, tabId?.uuid].compactMap { $0 })
        }
        if closePanel {
            panel?.close()
        }

        let shouldPreserveRemoteDisconnectOnClose =
            origin == "tab_close" ||
            origin == "pane_close"
        if shouldPreserveRemoteDisconnectOnClose,
           panel is TerminalPanel {
            markRemoteTerminalSessionClosingIfLast(surfaceId: panelId)
        }
        let shouldRefreshRemoteDisconnectPlaceholder =
            shouldPreserveRemoteDisconnectOnClose &&
            remoteDisconnectPlaceholderPanelIds.remove(panelId) != nil &&
            panels.count == 1
        if shouldRefreshRemoteDisconnectPlaceholder,
           let remoteConfiguration {
            rememberPendingRemoteDisconnectReplacement(configuration: remoteConfiguration)
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        discardRemoteDirectoryTrustState(panelId: panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        removeSurfaceMappings(forPanelId: panelId)

        panelDirectories.removeValue(forKey: panelId)
        panelDirectoryDisplayLabels.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        panelCustomTitleSources.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        clearAgentLifecycleStates(panelId: panelId)
        statusEntriesByPanelId.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        discardRemotePTYSessionID(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
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
