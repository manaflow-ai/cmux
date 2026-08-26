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
        agentLifecycleRecordsByPanelId.mapValues { records in
            records.mapValues(\.state)
        }
    }

    var agentLifecycleRecordsByPanelId: [UUID: [String: AgentLifecycleRecord]] {
        get { sidebarAgentRuntimeObservation.agentLifecycleRecordsByPanelId }
        set { sidebarAgentRuntimeObservation.setAgentLifecycleRecordsByPanelId(newValue) }
    }

    func takeNextAgentLifecycleRevision() -> UInt64 {
        sidebarAgentRuntimeObservation.takeNextAgentLifecycleRevision()
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
        // Claude's `claude_code` key identifies only a panel, not a session, so it
        // cannot prove that a live process supersedes this cached session generation.
        guard kind != .claude else { return [] }
        let key = "\(kind.rawValue).\(sessionId)"
        guard agentPIDKeysByPanelId[panelId]?.contains(key) == true,
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
        let lifecycleRecords = (agentLifecycleRecordsByPanelId[panelId] ?? [:]).filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }
        let lifecycleStates = lifecycleRecords.mapValues(\.state)
        let lifecycleSessionIDs = lifecycleRecords.compactMapValues(\.sessionID)

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
            agentLifecycleStates: lifecycleStates,
            agentLifecycleSessionIDs: lifecycleSessionIDs
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
    private func clearOtherStructuredAgentRuntimes(
        onPanel panelId: UUID,
        keeping retainedKey: String,
        preservingLifecycleStatusKey: String? = nil
    ) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if clearAgentPID(
                key: staleKey,
                panelId: panelId,
                clearStatus: true,
                refreshPorts: false,
                clearLifecycle: agentStatusKey(forAgentPIDKey: staleKey)
                    != preservingLifecycleStatusKey
            ) {
                didChange = true
            }
        }
        return didChange
    }
    @discardableResult
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        refreshPorts: Bool = true,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil
    ) -> Bool {
        recordAgentPIDOutcome(
            key: key,
            pid: pid,
            panelId: panelId,
            refreshPorts: refreshPorts,
            expectedLifecycleSessionID: expectedLifecycleSessionID,
            expectedPIDStartSeconds: expectedPIDStartSeconds,
            expectedPIDStartMicroseconds: expectedPIDStartMicroseconds
        ).didReplaceRuntime
    }

    func recordAgentPIDOutcome(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        refreshPorts: Bool = true,
        expectedLifecycleSessionID: String? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        preservingLifecycleStatusKey: String? = nil,
        commit: Bool = true
    ) -> (
        accepted: Bool,
        didReplaceRuntime: Bool,
        matchedExistingProcessGeneration: Bool
    ) {
        if let expectedLifecycleSessionID {
            guard let panelId,
                  agentLifecycleRecordsByPanelId[panelId]?[agentStatusKey(forAgentPIDKey: key)]?.sessionID
                    == expectedLifecycleSessionID else {
                return (false, false, false)
            }
        }
        let processIdentity = Self.agentPIDProcessIdentity(pid: pid)
        let expectedProcessIdentity: AgentPIDProcessIdentity?
        switch (expectedPIDStartSeconds, expectedPIDStartMicroseconds) {
        case (nil, nil):
            expectedProcessIdentity = nil
        case let (startSeconds?, startMicroseconds?):
            expectedProcessIdentity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds
            )
        case (nil, _?), (_?, nil):
            return (false, false, false)
        }
        let previous = (
            panelId: agentPIDPanelIdsByKey[key],
            pid: agentPIDs[key],
            identity: agentPIDProcessIdentitiesByKey[key]
        )
        let previousAgentPortRoots = refreshPorts ? trackedAgentPortRoots() : nil
        var matchedExistingProcessGeneration = false
        if let expectedProcessIdentity {
            matchedExistingProcessGeneration = previous.identity == expectedProcessIdentity
            if let previousIdentity = previous.identity {
                if previousIdentity == expectedProcessIdentity {
                    guard previous.pid == nil || previous.pid == pid else {
                        return (false, false, false)
                    }
                } else if !previousIdentity.startedBefore(expectedProcessIdentity) {
                    return (false, false, false)
                }
            } else if let previousPID = previous.pid,
                      previousPID != pid,
                      Self.agentPIDProcessIdentity(pid: previousPID) != nil {
                // Legacy partial ownership cannot be displaced while its
                // different process is still live; once dead, the verified
                // incoming generation is the only authoritative claimant.
                return (false, false, false)
            } else if previous.pid == nil, previous.panelId != nil {
                // A key-only owner has no process evidence that can be
                // causally ordered against this claimant.
                return (false, false, false)
            }
            if let panelId {
                let structuredKeys = agentPIDKeysByPanelId[panelId] ?? []
                for existingKey in structuredKeys where
                    existingKey != key && isStructuredAgentHookPIDKey(existingKey) {
                    if let existingIdentity = agentPIDProcessIdentitiesByKey[existingKey] {
                        if existingIdentity == expectedProcessIdentity {
                            matchedExistingProcessGeneration = true
                        }
                        guard existingIdentity == expectedProcessIdentity
                                || existingIdentity.startedBefore(expectedProcessIdentity) else {
                            return (false, false, false)
                        }
                    } else if let existingPID = agentPIDs[existingKey],
                              existingPID != pid,
                              Self.agentPIDProcessIdentity(pid: existingPID) != nil {
                        // An unversioned live owner cannot be ordered against
                        // this claimant, so neither side may displace it.
                        return (false, false, false)
                    } else if agentPIDs[existingKey] == nil {
                        return (false, false, false)
                    }
                }

                if let lifecycleKeys = agentLifecycleRecordsByPanelId[panelId]?.keys {
                    let incomingStatusKey = agentStatusKey(forAgentPIDKey: key)
                    for lifecycleKey in lifecycleKeys where
                        lifecycleKey != incomingStatusKey
                            && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(lifecycleKey) {
                        let hasVersionedOwner = structuredKeys.contains {
                            agentStatusKey(forAgentPIDKey: $0) == lifecycleKey
                        }
                        guard hasVersionedOwner else {
                            // A lifecycle with no process generation has no safe
                            // causal order relative to an anonymous claimant.
                            return (false, false, false)
                        }
                    }
                }
            }
            // A command queued by the recorded generation remains authorized
            // after that process exits. A new or replacing claim still needs
            // a live kernel identity at this mutation boundary.
            guard matchedExistingProcessGeneration
                    || processIdentity == expectedProcessIdentity else {
                return (false, false, false)
            }
        }
        guard commit else {
            return (true, false, matchedExistingProcessGeneration)
        }
        let didReplaceRecordedProcessGeneration = expectedProcessIdentity != nil
            && (previous.panelId != nil || previous.pid != nil || previous.identity != nil)
            && !matchedExistingProcessGeneration
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(
                onPanel: panelId,
                keeping: key,
                preservingLifecycleStatusKey: preservingLifecycleStatusKey
            )
        }
        let recordedProcessIdentity = expectedProcessIdentity ?? processIdentity
        agentPIDs[key] = pid
        agentPIDProcessIdentitiesByKey[key] = recordedProcessIdentity
        if let panelId { recordAgentPIDOwnership(key: key, panelId: panelId) } else { removeAgentPIDOwnership(key: key) }
        if previous.pid != pid || previous.panelId != panelId || previous.identity != recordedProcessIdentity {
            for changedPanelId in (previous.panelId == panelId ? [panelId] : [previous.panelId, panelId]).compactMap({ $0 }) {
                AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId)
            }
        }
        if let previousAgentPortRoots {
            let currentAgentPortRoots = trackedAgentPortRoots()
            // Lifecycle-only updates for an exact owner arrive on every hook
            // event. Rescan only when the scanner's authoritative root set
            // actually changes; an unchanged set would launch redundant ps/lsof work.
            if currentAgentPortRoots != previousAgentPortRoots {
                PortScanner.shared.refreshAgentPorts(
                    workspaceId: id,
                    agentRoots: currentAgentPortRoots
                )
            }
        }
        return (
            true,
            didClearOtherStructuredAgentRuntime || didReplaceRecordedProcessGeneration,
            matchedExistingProcessGeneration
        )
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
        refreshPorts: Bool = true,
        expectedLifecycleSessionID: String? = nil,
        expectedPID: pid_t? = nil,
        expectedPIDStartSeconds: Int64? = nil,
        expectedPIDStartMicroseconds: Int64? = nil,
        clearLifecycle: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if requireOwnedKey, ownedPanelId == nil {
            return false
        }
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        if let expectedPID {
            guard agentPIDs[key] == expectedPID else { return false }
            switch (expectedPIDStartSeconds, expectedPIDStartMicroseconds) {
            case (nil, nil):
                break
            case let (startSeconds?, startMicroseconds?):
                guard agentPIDProcessIdentitiesByKey[key] == AgentPIDProcessIdentity(
                    pid: expectedPID,
                    startSeconds: startSeconds,
                    startMicroseconds: startMicroseconds
                ) else {
                    return false
                }
            case (nil, _?), (_?, nil):
                return false
            }
        } else if expectedPIDStartSeconds != nil || expectedPIDStartMicroseconds != nil {
            return false
        }
        let statusKeyToClear = clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil
        if let expectedLifecycleSessionID,
           let lifecyclePanelID = ownedPanelId ?? panelId,
           let lifecycleRecord = agentLifecycleRecordsByPanelId[lifecyclePanelID]?[agentStatusKey(forAgentPIDKey: key)],
           lifecycleRecord.sessionID != expectedLifecycleSessionID {
            return false
        }

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
        if let changedPanelId = ownedPanelId ?? panelId, didChange { AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId) }
        if clearLifecycle, let lifecyclePanelId = ownedPanelId ?? panelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            if clearAgentLifecycle(
                key: lifecycleStatusKey,
                panelId: lifecyclePanelId,
                expectedSessionID: expectedLifecycleSessionID
            ) {
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

    /// Clears a panel's restored agent snapshot and resume metadata.
    func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
    }

    private func trackedAgentPortRoots() -> Set<AgentPortRootIdentity> {
        // Preserve the published snapshot until PortScanner reconciles the new
        // process tree; eagerly clearing here made every PID refresh flicker.
        Set(agentPIDs.compactMap { key, pid -> AgentPortRootIdentity? in
            guard pid > 0 else { return nil }
            return AgentPortRootIdentity(
                pid: Int(pid),
                processIdentity: agentPIDProcessIdentitiesByKey[key]
            )
        })
    }

    func refreshTrackedAgentPorts() {
        PortScanner.shared.refreshAgentPorts(
            workspaceId: id,
            agentRoots: trackedAgentPortRoots()
        )
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
