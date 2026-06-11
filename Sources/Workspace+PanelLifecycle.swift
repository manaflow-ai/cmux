import Bonsplit
import Darwin
import Foundation

extension Workspace {
    private static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
    private static let managedSubagentEnvironmentKey = "CMUX_AGENT_MANAGED_SUBAGENT"
    private static let truthyStartupEnvironmentValues: Set<String> = ["1", "true", "yes", "on", "enabled"]

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

    private func agentStatusKey(forAgentPIDKey key: String) -> String {
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

    /// Records an agent PID that is coupled to a visible sidebar status entry
    /// (the `set_status --pid` path, which inserts the status first and records
    /// the PID afterward). If the status entry did not survive the status cap —
    /// e.g. a flood of low-priority keys that each self-evict on insert while the
    /// workspace is already at cap with higher-priority entries — the PID is not
    /// retained, so the coupled `agentPIDs` / ownership / port-scan state stays
    /// bounded too (#5845). `set_agent_pid`, which intentionally tracks a PID
    /// without any status entry, must keep using `recordAgentPID` directly.
    @discardableResult
    func recordAgentPIDForSurvivingStatusKey(_ key: String, pid: pid_t, panelId: UUID?) -> Bool {
        guard statusEntries[key] != nil else { return false }
        return recordAgentPID(key: key, pid: pid, panelId: panelId)
    }

    func suppressesRawTerminalNotification(panelId: UUID?) -> Bool {
        guard let panelId else {
            return false
        }

        if AgentSubagentNotificationSettings.suppressNotifications(),
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

    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.filter { entry in
            shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys)
        }
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard Self.structuredAgentHookStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        var visibleStatusKeys = Set<String>()
        for statusKeys in statusKeysByPanelId.values {
            let winningEntry = statusKeys.compactMap { statusEntries[$0] }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard Self.structuredAgentHookStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
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
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let lifecyclePanelId = ownedPanelId ?? panelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            if clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
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

    /// Status keys backed by active agent runtime — either a coupled agent PID /
    /// ownership record, or an agent lifecycle state (e.g. a `needsInput` badge
    /// recorded via `setAgentLifecycle` with no PID, as `FeedCoordinator` does).
    /// The status cap ranks these ahead of plain telemetry so a noisy flood of
    /// distinct keys can't evict an active agent status — one whose display
    /// timestamp went stale because its updates were no-ops, or a pending
    /// needs-input decision — and hide it (#5845).
    func statusKeysWithCoupledAgentRuntime() -> Set<String> {
        var keys = Set<String>()
        for pidKey in agentPIDs.keys {
            keys.insert(agentStatusKey(forAgentPIDKey: pidKey))
        }
        for pidKey in agentPIDPanelIdsByKey.keys {
            keys.insert(agentStatusKey(forAgentPIDKey: pidKey))
        }
        // Lifecycle state is keyed directly by status key (per panel).
        for lifecycleStates in agentLifecycleStatesByPanelId.values {
            keys.formUnion(lifecycleStates.keys)
        }
        return keys
    }

    /// Clears the agent runtime state coupled to status keys that the sidebar
    /// status cap is about to evict, so that coupled state stays bounded too
    /// (#5845). Two couplings exist:
    ///  - `set_status --pid` records PIDs under keys derived from the status key
    ///    (`agentStatusKey(forAgentPIDKey:)`); leaving them orphans the
    ///    `agentPIDs` / ownership maps and the port-scan tags keyed off them.
    ///  - lifecycle-backed statuses (e.g. FeedCoordinator `needsInput`) record
    ///    `agentLifecycleStatesByPanelId[panelId][statusKey]` with no PID;
    ///    leaving them orphans that dictionary, which `statusKeysWithCoupledAgentRuntime()`
    ///    re-materializes on every later trim.
    /// Must run while the evicted entries are still present in `statusEntries` so
    /// `agentStatusKey(forAgentPIDKey:)` resolves dotted status keys correctly.
    func purgeAgentRuntimeState(forEvictedStatusKeys evictedStatusKeys: Set<String>) {
        guard !evictedStatusKeys.isEmpty else { return }
        var didChange = false
        let pidKeysToClear = Set(agentPIDs.keys)
            .union(agentPIDPanelIdsByKey.keys)
            .filter { evictedStatusKeys.contains(agentStatusKey(forAgentPIDKey: $0)) }
        for pidKey in pidKeysToClear {
            // clearStatus: false — the cap removes the status entries itself; this
            // only tears down the coupled PID/ownership/lifecycle records.
            if clearAgentPID(key: pidKey, panelId: nil, clearStatus: false, refreshPorts: false) {
                didChange = true
            }
        }
        // Clear lifecycle-only state (no PID) for evicted keys. Idempotent for
        // keys whose lifecycle `clearAgentPID` already cleared above.
        for statusKey in evictedStatusKeys where clearAgentLifecycle(key: statusKey) {
            didChange = true
        }
        if didChange {
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
        // Merge all adopted statuses in a single assignment so the cap ranks them
        // together in one trim (all share the just-inserted grace tier) instead
        // of letting earlier-adopted statuses age out of that tier as later ones
        // are written.
        if !runtimeState.statusEntries.isEmpty {
            var merged = statusEntries
            for (statusKey, statusEntry) in runtimeState.statusEntries {
                merged[statusKey] = statusEntry
            }
            statusEntries = merged
        }
        // Only adopt the coupled PID/ownership for a status-backed key if its
        // status actually survived the destination workspace's cap, so an adopted
        // status that self-evicted (destination already full of higher-ranked
        // live/reserved entries) can't recreate orphan agent runtime state
        // (#5845). PID-only keys (no status in the transferred runtime, e.g.
        // `set_agent_pid`) are always adopted.
        func adoptedStatusSurvived(forAgentPIDKey key: String) -> Bool {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard runtimeState.statusEntries[statusKey] != nil else { return true }
            return statusEntries[statusKey] != nil
        }
        var didAdoptAgentPID = false
        for (key, pid) in runtimeState.agentPIDs where adoptedStatusSurvived(forAgentPIDKey: key) {
            recordAgentPID(key: key, pid: pid, panelId: runtimeState.panelId, refreshPorts: false)
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys
        where runtimeState.agentPIDs[key] == nil && adoptedStatusSurvived(forAgentPIDKey: key) {
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
        cleanupControllerSurfaceState: Bool = false,
        ephemeralWorktreeCleanupAuthorized: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId, tabId?.uuid].compactMap { $0 })
        }
        if closePanel {
            panel?.close()
        }

        let ephemeralWorktree = ephemeralWorktreesByPanelId.removeValue(forKey: panelId)

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
        clearAgentLifecycleStates(panelId: panelId)
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
        if closePanel, let ephemeralWorktree {
            EphemeralWorktreeRegistry.shared.cleanupInBackground(
                ephemeralWorktree,
                userConfirmed: ephemeralWorktreeCleanupAuthorized
            )
        }
        return transferredRemoteCleanupConfiguration
    }
}
