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
        sidebarAgentRuntimeObservation.agentLifecycleStatesByPanelId
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
        // A shared-process key identifies the integration on this panel, not
        // one session, so it cannot supersede an exact cached session generation.
        guard BuiltInAgentIntegration(feedSourceName: kind.rawValue)?
            .lifecycleProcessOwnershipScope != .sharedProcess else {
            return []
        }
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
        let lifecycleStates = (agentLifecycleStatesByPanelId[panelId] ?? [:]).filter {
            !AgentHibernationLifecycleStatusKeys(rawValue: $0.key).isManual
        }
        let reconciliationState =
            sidebarAgentRuntimeObservation
                .transferableAgentLifecycleReconciliationSnapshot(
                    for: panelId
                )

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
        for statusKey in lifecycleStates.keys {
            if let statusEntry = statusEntries[statusKey] {
                statusEntriesForPanel[statusKey] = statusEntry
            }
        }
        guard !statusEntriesForPanel.isEmpty
                || !agentPIDsForPanel.isEmpty
                || !pidKeys.isEmpty
                || !lifecycleStates.isEmpty
                || reconciliationState.hasEvidence else {
            return nil
        }
        return DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: statusEntriesForPanel,
            agentPIDs: agentPIDsForPanel,
            agentPIDProcessIdentities: agentPIDIdentitiesForPanel,
            agentPIDKeys: pidKeys,
            agentLifecycleStates: lifecycleStates,
            agentLifecycleReconciliationState: reconciliationState
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

    /// Built-in lifecycle socket evidence is accepted only while at least one
    /// exact process generation for that status key still owns this panel.
    /// This prevents a standalone or delayed `set_agent_lifecycle` command
    /// from manufacturing a pill after its emitting process has exited.
    func hasLiveAgentProcess(
        statusKey: String,
        panelId: UUID,
        matching requiredGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        (agentPIDKeysByPanelId[panelId] ?? []).contains { pidKey in
            guard agentStatusKey(forAgentPIDKey: pidKey) == statusKey,
                  let pid = agentPIDs[pidKey],
                  let recordedIdentity =
                    agentPIDProcessIdentitiesByKey[pidKey],
                  recordedIdentity.pid == pid,
                  requiredGeneration == nil
                    || recordedIdentity == requiredGeneration else {
                return false
            }
            return Self.agentPIDProcessIdentity(pid: pid)
                == recordedIdentity
        }
    }

    private func hasAgentRuntime(
        forStatusKey statusKey: String,
        excluding excludedKey: String? = nil
    ) -> Bool {
        for key in agentPIDs.keys
        where key != excludedKey
            && agentStatusKey(forAgentPIDKey: key) == statusKey {
            return true
        }
        for key in agentPIDPanelIdsByKey.keys
        where key != excludedKey
            && agentStatusKey(forAgentPIDKey: key) == statusKey {
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
    private func clearOtherStructuredAgentRuntimes(
        onPanel panelId: UUID,
        keeping retainedKey: String,
        processGeneration retainedGeneration: AgentPIDProcessIdentity?
    ) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let retainedStatusKey = agentStatusKey(forAgentPIDKey: retainedKey)
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            if agentStatusKey(forAgentPIDKey: staleKey) == retainedStatusKey,
               let retainedGeneration,
               agentPIDProcessIdentitiesByKey[staleKey]
                    == retainedGeneration {
                continue
            }
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
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
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        refreshPorts: Bool = true,
        observeProcessExit: Bool = true
    ) -> Bool {
        recordAgentPIDResult(
            key: key,
            pid: pid,
            panelId: panelId,
            processIdentity: providedProcessIdentity,
            refreshPorts: refreshPorts,
            observeProcessExit: observeProcessExit
        ).replacedOtherRuntime
    }

    /// Admits an exact process generation before replacing any runtime owner.
    func recordAgentPIDResult(
        key: String,
        pid: pid_t,
        panelId: UUID?,
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        refreshPorts: Bool = true,
        observeProcessExit: Bool = true
    ) -> (accepted: Bool, replacedOtherRuntime: Bool) {
        let previous = (
            panelId: agentPIDPanelIdsByKey[key],
            pid: agentPIDs[key],
            identity: agentPIDProcessIdentitiesByKey[key]
        )
        let processIdentity =
            providedProcessIdentity
                ?? Self.agentPIDProcessIdentity(pid: pid)
        if let processIdentity,
           previous.panelId == panelId,
           previous.pid == pid,
           previous.identity == processIdentity {
            return (accepted: true, replacedOtherRuntime: false)
        }
        if let processIdentity,
           let previousIdentity = previous.identity,
           processIdentity < previousIdentity {
            return (accepted: false, replacedOtherRuntime: false)
        }
        if let panelId, let processIdentity {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard sidebarAgentRuntimeObservation.recordAgentProcessGeneration(
                key: statusKey,
                panelId: panelId,
                generation: processIdentity,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(
                    rawValue: statusKey
                ).isAllowed
            ) else {
                return (accepted: false, replacedOtherRuntime: false)
            }
        }
        let replacesProcessGeneration =
            previous.identity != nil
                && previous.identity != processIdentity
        if let previousPanelId = previous.panelId,
           let previousIdentity = previous.identity,
           previousPanelId != panelId || replacesProcessGeneration {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if sidebarAgentRuntimeObservation.recordAgentProcessExit(
                key: statusKey,
                panelId: previousPanelId,
                generation: previousIdentity
            ) {
                AgentHibernationController.shared.recordAgentLifecycleChange(
                    workspaceId: id,
                    panelId: previousPanelId
                )
            }
        }
        if replacesProcessGeneration {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            if !hasAgentRuntime(
                forStatusKey: statusKey,
                excluding: key
            ) {
                statusEntries.removeValue(forKey: statusKey)
            }
            if let previousPanelId = previous.panelId {
                AppDelegate.shared?.notificationStore?.clearNotifications(
                    forTabId: id,
                    surfaceId: previousPanelId
                )
            }
        }
        var didClearOtherStructuredAgentRuntime = false
        if let panelId {
            didClearOtherStructuredAgentRuntime =
                clearOtherStructuredAgentRuntimes(
                    onPanel: panelId,
                    keeping: key,
                    processGeneration: processIdentity
                )
        }
        agentPIDs[key] = pid
        if let processIdentity {
            agentPIDProcessIdentitiesByKey[key] = processIdentity
        } else {
            agentPIDProcessIdentitiesByKey.removeValue(forKey: key)
        }
        if let panelId { recordAgentPIDOwnership(key: key, panelId: panelId) } else { removeAgentPIDOwnership(key: key) }
        sidebarAgentRuntimeObservation.cancelAgentProcessExitObservation(key: key)
        if observeProcessExit, panelId != nil, let processIdentity {
            sidebarAgentRuntimeObservation.observeAgentProcessExit(
                key: key,
                generation: processIdentity
            ) { [weak self] key, generation in
                self?.handleObservedAgentProcessExit(
                    key: key,
                    generation: generation
                )
            }
        }
        if previous.pid != pid || previous.panelId != panelId || previous.identity != processIdentity {
            for changedPanelId in (previous.panelId == panelId ? [panelId] : [previous.panelId, panelId]).compactMap({ $0 }) {
                AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId)
            }
        }
        if refreshPorts { refreshTrackedAgentPorts() }
        return (
            accepted: true,
            replacedOtherRuntime: didClearOtherStructuredAgentRuntime
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
        sidebarAgentRuntimeObservation.cancelAllAgentProcessExitObservations()
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

    private func handleObservedAgentProcessExit(
        key: String,
        generation: AgentPIDProcessIdentity
    ) {
        guard agentPIDs[key] == generation.pid,
              agentPIDProcessIdentitiesByKey[key] == generation else {
            return
        }
        let panelId = agentPIDPanelIdsByKey[key]
        guard clearAgentPID(
            key: key,
            panelId: panelId,
            clearStatus: true,
            refreshPorts: true
        ) else {
            return
        }
        guard let panelId else { return }
        AppDelegate.shared?.notificationStore?.clearNotifications(
            forTabId: id,
            surfaceId: panelId
        )
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
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if requireOwnedKey, ownedPanelId == nil {
            return false
        }
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let lifecyclePanelId = ownedPanelId ?? panelId
        let statusKeyToClear =
            clearStatus ? agentStatusKey(forAgentPIDKey: key) : nil
        let hadFeedAttention: Bool
        if let statusKeyToClear, let lifecyclePanelId {
            hadFeedAttention = sidebarAgentRuntimeObservation
                .hasAgentFeedAttention(
                    key: statusKeyToClear,
                    panelId: lifecyclePanelId
                )
        } else {
            hadFeedAttention = false
        }
        let recordedProcessIdentity = agentPIDProcessIdentitiesByKey[key]
        sidebarAgentRuntimeObservation.cancelAgentProcessExitObservation(key: key)

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
        if let changedPanelId = lifecyclePanelId, didChange { AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId) }
        if let lifecyclePanelId {
            let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
            let remainingKeys = agentPIDKeysByPanelId[lifecyclePanelId] ?? []
            let hasRemainingStatusRuntime = remainingKeys.contains {
                agentStatusKey(forAgentPIDKey: $0) == lifecycleStatusKey
            }
            let hasRemainingGenerationOwner = recordedProcessIdentity.map {
                generation in
                remainingKeys.contains {
                    agentStatusKey(forAgentPIDKey: $0)
                        == lifecycleStatusKey
                        && agentPIDProcessIdentitiesByKey[$0]
                            == generation
                }
            } ?? false
            let didClearLifecycle: Bool
            if let recordedProcessIdentity,
               !hasRemainingGenerationOwner {
                didClearLifecycle = sidebarAgentRuntimeObservation.recordAgentProcessExit(
                    key: lifecycleStatusKey,
                    panelId: lifecyclePanelId,
                    generation: recordedProcessIdentity
                )
            } else if AgentHibernationLifecycleStatusKeys(
                rawValue: lifecycleStatusKey
            ).isAllowed,
                      !hasRemainingStatusRuntime {
                didClearLifecycle = sidebarAgentRuntimeObservation
                    .recordUnidentifiedAgentProcessExit(
                        key: lifecycleStatusKey,
                        panelId: lifecyclePanelId,
                        isBuiltIn: true
                    )
            } else if !hasRemainingStatusRuntime {
                didClearLifecycle = sidebarAgentRuntimeObservation.removeAgentLifecycleKey(
                    key: lifecycleStatusKey,
                    panelId: lifecyclePanelId
                )
            } else {
                didClearLifecycle = false
            }
            if didClearLifecycle {
                didChange = true
                if !AgentHibernationLifecycleStatusKeys(
                    rawValue: lifecycleStatusKey
                ).isManual {
                    AgentHibernationController.shared.recordAgentLifecycleChange(
                        workspaceId: id,
                        panelId: lifecyclePanelId
                    )
                }
            }
        }
        if let statusKeyToClear,
           statusEntries[statusKeyToClear] != nil {
            let feedAttentionStillVisible =
                lifecyclePanelId.map {
                    sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                        key: statusKeyToClear,
                        panelId: $0
                    )
                } ?? false
            if !hasAgentRuntime(forStatusKey: statusKeyToClear)
                || (hadFeedAttention && !feedAttentionStillVisible) {
                statusEntries.removeValue(forKey: statusKeyToClear)
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

    func adoptDetachedAgentRuntimeState(
        _ runtimeState: DetachedAgentRuntimeState?,
        isRemoteTerminal: Bool = false
    ) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        let hasReconciliationEvidence =
            runtimeState.agentLifecycleReconciliationState.hasEvidence
        if hasReconciliationEvidence {
            sidebarAgentRuntimeObservation
                .adoptAgentLifecycleReconciliationSnapshot(
                    runtimeState.agentLifecycleReconciliationState,
                    panelId: runtimeState.panelId
                )
        }
        var didAdoptAgentPID = false
        var rejectedStatusKeys: Set<String> = []
        for (key, pid) in runtimeState.agentPIDs {
            let recordedIdentity =
                runtimeState.agentPIDProcessIdentities[key]
            if let recordedIdentity,
               !isRemoteTerminal,
               Self.agentPIDProcessIdentity(pid: pid) != recordedIdentity {
                let statusKey = agentStatusKey(forAgentPIDKey: key)
                rejectedStatusKeys.insert(statusKey)
                _ = sidebarAgentRuntimeObservation.recordAgentProcessExit(
                    key: statusKey,
                    panelId: runtimeState.panelId,
                    generation: recordedIdentity
                )
                statusEntries.removeValue(forKey: statusKey)
                continue
            }
            recordAgentPID(
                key: key,
                pid: pid,
                panelId: runtimeState.panelId,
                processIdentity: recordedIdentity,
                refreshPorts: false,
                observeProcessExit: !isRemoteTerminal
            )
            didAdoptAgentPID = true
        }
        for key in runtimeState.agentPIDKeys where runtimeState.agentPIDs[key] == nil {
            recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
        }
        if !hasReconciliationEvidence {
            for (key, lifecycle) in runtimeState.agentLifecycleStates
            where !rejectedStatusKeys.contains(key) {
                setAgentLifecycle(
                    key: key,
                    panelId: runtimeState.panelId,
                    lifecycle: lifecycle
                )
            }
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
        if !preservesTerminalForTransfer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: id,
                panelId: panelId
            )
        }
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
