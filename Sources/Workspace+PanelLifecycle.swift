import Bonsplit
import CmuxSettings
import CmuxCore
import Darwin
import Foundation
import CmuxSidebar

extension Workspace {
    private static let structuredAgentHookStatusKeys = AgentHibernationLifecycleStatusKeys.allowedStatusKeys
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

    /// Returns exact-session runtime identities that still match their recorded process generation.
    func confirmedRuntimeAgentProcessIdentities(
        for agent: SessionRestorableAgentSnapshot,
        panelId: UUID,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?
    ) -> Set<AgentPIDProcessIdentity> {
        confirmedRuntimeAgentProcessIdentities(
            kind: agent.kind,
            sessionId: agent.sessionId,
            panelId: panelId,
            currentProcessIdentity: currentProcessIdentity
        )
    }

    /// Returns exact-session runtime identities that still match their recorded process generation.
    func confirmedRuntimeAgentProcessIdentities(
        kind: RestorableAgentKind,
        sessionId: String,
        panelId: UUID,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?
    ) -> Set<AgentPIDProcessIdentity> {
        // Claude hooks historically used a workspace-global `claude_code` key;
        // current writes are normalized to the same session-scoped shape as
        // every other managed agent, so concurrent panes remain attributable.
        let keys = kind == .claude
            ? [
                "claude_code.\(sessionId)",
                "claude_code.panel.\(panelId.uuidString.lowercased())",
            ]
            : ["\(kind.rawValue).\(sessionId)"]
        guard let key = keys.first(where: { agentPIDKeysByPanelId[panelId]?.contains($0) == true }),
              let pid = agentPIDs[key],
              pid > 0,
              let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
              recordedIdentity.pid == pid,
              currentProcessIdentity(Int(pid)) == recordedIdentity else {
            return []
        }
        return [recordedIdentity]
    }

    func agentRuntimeState(forPanelId panelId: UUID) -> DetachedAgentRuntimeState? {
        let pidKeys = agentPIDKeysByPanelId[panelId] ?? []
        let lifecycleStates = (agentLifecycleStatesByPanelId[panelId] ?? [:]).filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }

        var agentPIDsForPanel: [String: pid_t] = [:]
        var agentPIDIdentitiesForPanel: [String: AgentPIDProcessIdentity] = [:]
        var statusEntriesForPanel: [String: SidebarStatusEntry] = [:]
        for key in pidKeys {
            if let pid = agentPIDs[key] {
                agentPIDsForPanel[key] = pid
                agentPIDIdentitiesForPanel[key] = agentPIDProcessIdentitiesByKey[key]
            }
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        for (statusKey, lifecycle) in lifecycleStates where lifecycle == .needsInput {
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty
                || !agentPIDsForPanel.isEmpty
                || !pidKeys.isEmpty
                || !lifecycleStates.isEmpty else {
            return nil
        }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDProcessIdentities: agentPIDIdentitiesForPanel,
            agentPIDKeys: pidKeys,
            agentLifecycleStates: lifecycleStates
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
        if agentLifecycleStatesByPanelId.values.contains(where: {
            $0[statusKey] == .needsInput
        }) {
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
        // Claude's historical `claude_code` key was workspace-global. Keep
        // accepting that wire key, but persist a session-scoped key whenever
        // the panel has a managed binding so two Claude panes cannot evict one
        // another from `agentPIDPanelIdsByKey`.
        let storageKey = scopedAgentPIDKey(key: key, panelId: panelId)
        let previous = (
            panelId: agentPIDPanelIdsByKey[storageKey],
            pid: agentPIDs[storageKey],
            identity: agentPIDProcessIdentitiesByKey[storageKey]
        )
        var didClearOtherStructuredAgentRuntime = false
        if let panelId { didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(onPanel: panelId, keeping: storageKey) }
        let processIdentity = Self.agentPIDProcessIdentity(pid: pid)
        agentPIDs[storageKey] = pid
        agentPIDProcessIdentitiesByKey[storageKey] = processIdentity
        if let panelId { recordAgentPIDOwnership(key: storageKey, panelId: panelId) } else { removeAgentPIDOwnership(key: storageKey) }
        if previous.pid != pid || previous.panelId != panelId || previous.identity != processIdentity {
            for changedPanelId in (previous.panelId == panelId ? [panelId] : [previous.panelId, panelId]).compactMap({ $0 }) {
                AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId)
            }
        }
        if refreshPorts { refreshTrackedAgentPorts() }
        return didClearOtherStructuredAgentRuntime
    }

    /// Maps the legacy Claude PID key to a panel-scoped storage identity.
    /// Non-Claude keys retain their original spelling for compatibility.
    private func scopedAgentPIDKey(key: String, panelId: UUID?) -> String {
        guard key == "claude_code",
              let panelId else {
            return key
        }
        if let checkpointID = surfaceResumeBindingsByPanelId[panelId]?.checkpointId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !checkpointID.isEmpty {
            return "claude_code.\(checkpointID)"
        }
        // Unbound/manual callers still rely on the historical status-key
        // projection (`agentPIDs["claude_code"]`), so retain that spelling
        // until a managed binding supplies a session identity.
        return key
    }

    @discardableResult
    func clearStaleAgentPIDs(refreshPorts: Bool = true) -> Bool {
        var didChange = false
        for (key, pid) in agentPIDs where !isRecordedAgentPIDLive(key: key, pid: pid) {
            if clearAgentPID(key: key, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        if didChange {
            if refreshPorts { refreshTrackedAgentPorts() }
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id)
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
        if didChange {
            if refreshPorts { refreshTrackedAgentPorts() }
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }
        return didChange
    }

    func clearAllAgentPIDs(refreshPorts: Bool = true) {
        agentPIDs.removeAll()
        agentPIDProcessIdentitiesByKey.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        if refreshPorts {
            refreshTrackedAgentPorts()
        } else {
            agentListeningPorts.removeAll()
            recomputeListeningPorts()
            PortScanner.shared.unregisterAgentWorkspace(workspaceId: id)
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

    /// Reads the identity the port scanner and session restore compare against.
    ///
    /// Delegates rather than reading the process table itself: a second reader
    /// with different privilege behavior would record `nil` identities for
    /// agents running under another euid, which `PortScanner.validateAgentRoots`
    /// treats as permanently incomplete evidence.
    static func agentPIDProcessIdentity(pid: pid_t) -> AgentPIDProcessIdentity? {
        AgentPIDProcessIdentity(pid: pid)
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
        requireOwnedKey: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        // A panel-scoped legacy clear has no session identity. Do not derive a
        // replacement key from the panel's *current* binding: an old hook may
        // arrive after that binding has changed and would otherwise clear the
        // replacement session. Callers with a session identity must pass the
        // already-scoped key explicitly.
        let scopedKey = key == "claude_code" && panelId != nil
            ? key
            : scopedAgentPIDKey(key: key, panelId: panelId)
        var candidateKeys = [scopedKey]
        if key == "claude_code", panelId == nil {
            // Session teardown can clear the binding before issuing the legacy
            // bare-key command. Workspace-scoped cleanup may therefore clear
            // every Claude-scoped key, while panel-scoped cleanup stays exact.
            candidateKeys.append(contentsOf: agentPIDPanelIdsByKey.compactMap { candidate, owner in
                guard candidate.hasPrefix("claude_code.") else { return nil }
                return panelId == nil || owner == panelId ? candidate : nil
            })
        }
        var uniqueKeys: [String] = []
        var seenKeys = Set<String>()
        for candidate in candidateKeys where seenKeys.insert(candidate).inserted {
            uniqueKeys.append(candidate)
        }
        let ownedKeys = uniqueKeys.filter { candidate in
            guard let owner = agentPIDPanelIdsByKey[candidate] else { return false }
            return panelId == nil || owner == panelId
        }
        if requireOwnedKey, ownedKeys.isEmpty {
            return false
        }
        var didChange = false
        var changedPanelIDs = Set<UUID>()
        var lifecycleStatusKeysByPanelID: [UUID: Set<String>] = [:]
        var statusKeysToClear = Set<String>()
        for candidate in uniqueKeys {
            let ownedPanelId = agentPIDPanelIdsByKey[candidate]
            if let panelId, let ownedPanelId, ownedPanelId != panelId { continue }
            let statusKey = agentStatusKey(forAgentPIDKey: candidate)
            if clearStatus { statusKeysToClear.insert(statusKey) }
            if agentPIDs.removeValue(forKey: candidate) != nil { didChange = true }
            if agentPIDProcessIdentitiesByKey.removeValue(forKey: candidate) != nil { didChange = true }
            if ownedPanelId != nil {
                removeAgentPIDOwnership(key: candidate)
                didChange = true
            }
            if let changedPanelId = ownedPanelId ?? panelId {
                changedPanelIDs.insert(changedPanelId)
                lifecycleStatusKeysByPanelID[changedPanelId, default: []].insert(statusKey)
            }
        }
        for changedPanelID in changedPanelIDs {
            AgentHibernationController.shared.recordAgentProcessChange(
                workspaceId: id,
                panelId: changedPanelID
            )
        }
        for (lifecyclePanelID, statusKeys) in lifecycleStatusKeysByPanelID {
            for statusKey in statusKeys where clearAgentLifecycle(key: statusKey, panelId: lifecyclePanelID) {
                didChange = true
            }
        }
        for statusKey in statusKeysToClear where !hasAgentRuntime(forStatusKey: statusKey) {
            if statusEntries.removeValue(forKey: statusKey) != nil {
                didChange = true
            }
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    /// Clears a panel's restored agent snapshot and resume metadata.
    func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
    }

    func refreshTrackedAgentPorts() {
        // Preserve the published snapshot until PortScanner reconciles the new
        // process tree; eagerly clearing here made every PID refresh flicker.
        let remainingAgentRoots = Set(agentPIDs.compactMap { key, pid -> AgentPortRootIdentity? in
            guard pid > 0 else { return nil }
            return AgentPortRootIdentity(
                pid: Int(pid),
                processIdentity: agentPIDProcessIdentitiesByKey[key]
            )
        })
        PortScanner.shared.refreshAgentPorts(workspaceId: id, agentRoots: remainingAgentRoots)
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
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
        for (statusKey, capturedStatusEntry) in runtimeState.statusEntries
            where !hasAgentRuntime(forStatusKey: statusKey)
                && statusEntries[statusKey] == capturedStatusEntry {
            statusEntries.removeValue(forKey: statusKey)
            didChange = true
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
            if let recordedIdentity = runtimeState.agentPIDProcessIdentities[key] {
                agentPIDProcessIdentitiesByKey[key] = recordedIdentity
            }
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        for (key, lifecycle) in runtimeState.agentLifecycleStates {
            setAgentLifecycle(key: key, panelId: runtimeState.panelId, lifecycle: lifecycle)
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
        discardAgentHibernationTracking: Bool = true,
        cleanupControllerSurfaceState: Bool = false,
        preservesTerminalForTransfer: Bool = false
    ) -> WorkspaceRemoteConfiguration? {
        appLinkHandoffCoordinator.cancel(sourcePanelID: panelId)
        if publishSurfaceClosedEvent {
            publishCmuxSurfaceClosed(panelId, paneId: paneId, panel: panel, origin: origin)
        }

        let closedAgentRuntimeState = agentRuntimeState(forPanelId: panelId)
        removePendingTerminalInputObservers(forPanelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)?.cancel()
        (panel as? FilePreviewPanel)?.unbindTabMetadata()
        discardAgentSessionPanelSubscription(panelId: panelId, panel: panel)
        discardBrowserPanelSubscription(panelId: panelId, panel: panel)
        removeBrowserOpenTabSuggestionIfNeeded(panel: panel, panelId: panelId)
        if cleanupControllerSurfaceState {
            TerminalController.shared.cleanupSurfaceState(
                surfaceIds: [panelId, tabId?.uuid].compactMap { $0 }
            )
        }
        if !preservesTerminalForTransfer {
            removeDeferredAgentResumeRestore(panelId: panelId)
            terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(
                panelID: panelId
            )
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
        cancelPendingRemoteDisconnectReplacement(surfaceId: panelId)
        if shouldRefreshRemoteDisconnectPlaceholder,
           let remoteConfiguration {
            rememberPendingRemoteDisconnectReplacement(
                surfaceId: panelId,
                configuration: remoteConfiguration
            )
        }

        let removedPanel = panels.removeValue(forKey: panelId)
        if discardAgentHibernationTracking {
            AgentHibernationController.shared.discardTrackingStateForClosedPanel(
                workspaceId: id,
                panelId: panelId
            )
        }
        if let terminalPanel =
                (removedPanel ?? panel) as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalDidLeaveWorkspace(
                    terminalPanel,
                    workspace: self,
                    preservingTransfer:
                        preservesTerminalForTransfer
                )
        }
        untrackRemoteTerminalSurface(panelId)
        if closePanel {
            endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: panelId)
        }
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
        pinMutationTokensByPanelId.removeValue(forKey: panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        clearAgentLifecycleStates(panelId: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        discardRemotePTYSessionID(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        pendingPlainSSHRestorePanelIds.remove(panelId)
        observedPlainSSHPanelIds.remove(panelId)
        plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
#endif
        discardAgentRuntimeState(closedAgentRuntimeState)
        clearRestoredAgentSnapshot(panelId: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        removeTerminalConfigInheritanceSource(panelId: panelId)
        if clearSurfaceNotifications {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        }

        if requestTransferredRemoteCleanup, let transferredRemoteCleanupConfiguration {
            requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        return transferredRemoteCleanupConfiguration
    }
}
