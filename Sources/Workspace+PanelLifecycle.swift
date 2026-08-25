import Bonsplit
import CMUXAgentLaunch
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

    /// Returns the active binding or the metadata-cleared binding that still
    /// owns runtime delivery until a replacement or authoritative end arrives.
    func authoritativeAgentRuntimeBinding(
        panelId: UUID
    ) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
            ?? restoredAgentLifecycle.eligibleRetiredAgentRuntimeBinding(
                panelId: panelId
            )
    }

    /// Coalesces mixed-version transport aliases into one logical runtime.
    func logicalAgentPIDs() -> [String: pid_t] {
        let recordedPIDs = agentPIDs
        var aliasesToCanonicalKeys: [String: String] = [:]
        for key in recordedPIDs.keys {
            guard let structuredKey = AgentRuntimeSessionKey(rawValue: key) else {
                continue
            }
            for alias in structuredKey.compatibleRawValues {
                aliasesToCanonicalKeys[alias] = structuredKey.rawValue
            }
        }
        var logicalPIDs: [String: pid_t] = [:]
        // Prefer the legacy alias when both exist: an older hook may refresh it
        // alone after a process restart, while new hooks update both in order.
        let keysInAliasPreferenceOrder = recordedPIDs.keys.sorted { lhs, rhs in
            let lhsIsStructured = AgentRuntimeSessionKey(rawValue: lhs) != nil
            let rhsIsStructured = AgentRuntimeSessionKey(rawValue: rhs) != nil
            if lhsIsStructured != rhsIsStructured {
                return !lhsIsStructured
            }
            return lhs < rhs
        }
        for key in keysInAliasPreferenceOrder {
            let logicalKey = aliasesToCanonicalKeys[key] ?? key
            if logicalPIDs[logicalKey] == nil {
                logicalPIDs[logicalKey] = recordedPIDs[key]
            }
        }
        return logicalPIDs
    }

    /// Remote hook PIDs remain opaque after a panel moves into a workspace
    /// that does not adopt the source workspace's remote configuration.
    func agentRuntimeUsesRemoteProcessNamespace(panelId: UUID) -> Bool {
        isRemoteTerminalSurface(panelId)
            || surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[panelId] != nil
            || transferredRemoteCleanupConfigurationsByPanelId[panelId] != nil
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
        // A hook running inside a remote terminal reports a PID from the SSH
        // host. Never compare that opaque value with this Mac's process table.
        guard !agentRuntimeUsesRemoteProcessNamespace(panelId: panelId) else { return [] }
        // Claude's `claude_code` key identifies only a panel, not a session, so it
        // cannot prove that a live process supersedes this cached session generation.
        guard kind != .claude else { return [] }
        let compatibleKeys = AgentRuntimeSessionKey(
            statusKey: kind.lifecycleStatusKey,
            sessionID: sessionId
        ).compatibleRawValues
        let ownedKeys = agentPIDKeysByPanelId[panelId] ?? []
        return Set(compatibleKeys.compactMap { key -> AgentPIDProcessIdentity? in
            guard ownedKeys.contains(key),
                  let pid = agentPIDs[key],
                  pid > 0,
                  let recordedIdentity = agentPIDProcessIdentitiesByKey[key],
                  recordedIdentity.pid == pid,
                  currentProcessIdentity(Int(pid)) == recordedIdentity else {
                return nil
            }
            return recordedIdentity
        })
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
            let statusKey = agentStatusKey(forAgentPIDKey: key, panelId: panelId)
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

    func agentStatusKey(forAgentPIDKey key: String, panelId: UUID? = nil) -> String {
        if let structuredKey = AgentRuntimeSessionKey(rawValue: key) {
            return structuredKey.statusKey
        }
        if let panelId,
           let binding = authoritativeAgentRuntimeBinding(panelId: panelId),
           let statusKey = binding.agentRuntimeStatusKey,
           binding.matchesAgentRuntimeKeyForCleanup(key) {
            return statusKey
        }
        if let panelId,
           let retiredStatusKey = restoredAgentLifecycle.retiredAgentRuntimeStatusKey(
               for: key,
               panelId: panelId
           ) {
            return retiredStatusKey
        }
        if statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }

    private func hasAgentRuntime(forStatusKey statusKey: String) -> Bool {
        for key in agentPIDs.keys
        where agentStatusKey(
            forAgentPIDKey: key,
            panelId: agentPIDPanelIdsByKey[key]
        ) == statusKey {
            return true
        }
        for (key, panelId) in agentPIDPanelIdsByKey
        where agentStatusKey(forAgentPIDKey: key, panelId: panelId) == statusKey {
            return true
        }
        if agentLifecycleStatesByPanelId.values.contains(where: {
            $0[statusKey] == .needsInput
        }) {
            return true
        }
        return false
    }

    private func hasAgentRuntime(forStatusKey statusKey: String, onPanel panelId: UUID) -> Bool {
        (agentPIDKeysByPanelId[panelId] ?? []).contains {
            agentStatusKey(forAgentPIDKey: $0, panelId: panelId) == statusKey
        }
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
        if isStructuredAgentHookPIDKey(
            key,
            panelId: panelId,
            requiresCurrentSessionMatch: true
        ) {
            let statusKey = agentStatusKey(forAgentPIDKey: key, panelId: panelId)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key &&
                isStructuredAgentHookPIDKey(
                    $0,
                    panelId: panelId,
                    requiresCurrentSessionMatch: true
                ) &&
                agentStatusKey(forAgentPIDKey: $0, panelId: panelId) != statusKey
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
        guard isStructuredAgentHookPIDKey(
            retainedKey,
            panelId: panelId,
            requiresCurrentSessionMatch: true
        ) else { return false }
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        let currentBinding = authoritativeAgentRuntimeBinding(panelId: panelId)
        let retainedKeyMatchesCurrentBinding = currentBinding?
            .matchesExactAgentRuntimeKey(retainedKey) == true
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(
            staleKey,
            panelId: panelId,
            requiresCurrentSessionMatch: true
        ) && !(retainedKeyMatchesCurrentBinding
            && currentBinding?.matchesExactAgentRuntimeKey(staleKey) == true) {
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: true, refreshPorts: false) {
                didChange = true
            }
        }
        return didChange
    }
    @discardableResult
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID?, refreshPorts: Bool = true) -> Bool {
        let currentBinding = panelId.flatMap {
            authoritativeAgentRuntimeBinding(panelId: $0)
        }
        if currentBinding?.rejectsMismatchedAgentRuntimeKey(key) == true
            || panelId.map({
                restoredAgentLifecycle.rejectsSupersededAgentRuntimeKey(
                    key,
                    panelId: $0
                )
            }) == true {
            return false
        }
        let recordsCurrentBinding = currentBinding?.matchesExactAgentRuntimeKey(key) == true
        let previous = (
            panelId: agentPIDPanelIdsByKey[key],
            pid: agentPIDs[key],
            identity: agentPIDProcessIdentitiesByKey[key]
        )
        var didClearOtherStructuredAgentRuntime = false
        if let panelId { didClearOtherStructuredAgentRuntime = clearOtherStructuredAgentRuntimes(onPanel: panelId, keeping: key) }
        let storesLocalProcess = panelId.map {
            !agentRuntimeUsesRemoteProcessNamespace(panelId: $0)
        } ?? true
        let storedPID: pid_t? = storesLocalProcess ? pid : nil
        let processIdentity = storesLocalProcess ? Self.agentPIDProcessIdentity(pid: pid) : nil
        agentPIDs[key] = storedPID
        agentPIDProcessIdentitiesByKey[key] = processIdentity
        if let panelId { recordAgentPIDOwnership(key: key, panelId: panelId) } else { removeAgentPIDOwnership(key: key) }
        if previous.pid != storedPID || previous.panelId != panelId || previous.identity != processIdentity {
            for changedPanelId in (previous.panelId == panelId ? [panelId] : [previous.panelId, panelId]).compactMap({ $0 }) {
                AgentHibernationController.shared.recordAgentProcessChange(workspaceId: id, panelId: changedPanelId)
            }
        }
        if refreshPorts { refreshTrackedAgentPorts() }
        let carriesBindingReplacement = recordsCurrentBinding
            && currentBinding.flatMap { binding in
                panelId.map {
                    restoredAgentLifecycle.consumePendingAgentRuntimeReplacement(
                        for: binding,
                        panelId: $0
                    )
                }
            } == true
        return didClearOtherStructuredAgentRuntime || carriesBindingReplacement
    }

    @discardableResult
    func clearStaleAgentPIDs(refreshPorts: Bool = true) -> Bool {
        var didChange = false
        for (key, pid) in agentPIDs {
            if let panelId = agentPIDPanelIdsByKey[key],
               agentRuntimeUsesRemoteProcessNamespace(panelId: panelId) {
                continue
            }
            guard !isRecordedAgentPIDLive(key: key, pid: pid) else { continue }
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
        // Remote PID values are owned and retired by their terminal lifecycle;
        // they are not inspectable through this Mac's process table.
        guard !agentRuntimeUsesRemoteProcessNamespace(panelId: panelId) else { return false }
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

    /// Consumes structured remote-agent runtime after its prompt or terminal
    /// lifecycle ends, without touching unrelated panel runtime state.
    func clearRemoteAgentRuntime(panelId: UUID) {
        guard let binding = authoritativeAgentRuntimeBinding(panelId: panelId) else { return }
        clearAgentRuntimeOwned(by: binding, panelId: panelId)
    }

    /// Clears only runtime state whose kind-scoped key belongs to `binding`.
    func clearAgentRuntimeOwned(
        by binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        guard let statusKey = binding.agentRuntimeStatusKey else { return }
        let keys = (agentPIDKeysByPanelId[panelId] ?? []).filter {
            binding.matchesAgentRuntimeKeyForCleanup($0)
        }
        var didChange = false
        for key in keys {
            if clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: true,
                agentStatusKeyOverride: statusKey,
                refreshPorts: false
            ) {
                didChange = true
            }
        }
        if clearAgentLifecycle(key: statusKey, panelId: panelId) {
            didChange = true
        }
        if !hasAgentRuntime(forStatusKey: statusKey),
           statusEntries.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if didChange {
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
        return panelKeys.contains {
            isStructuredAgentHookPIDKey($0, panelId: panelId)
        }
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

    private func isStructuredAgentHookPIDKey(
        _ key: String,
        panelId: UUID? = nil,
        requiresCurrentSessionMatch: Bool = false
    ) -> Bool {
        if AgentRuntimeSessionKey(rawValue: key) != nil {
            return true
        }
        if let panelId,
           let binding = authoritativeAgentRuntimeBinding(panelId: panelId),
           binding.matchesAgentRuntimeKeyForCleanup(key) {
            return requiresCurrentSessionMatch
                ? binding.matchesExactAgentRuntimeKey(key)
                : true
        }
        if let panelId,
           let binding = authoritativeAgentRuntimeBinding(panelId: panelId),
           binding.isLegacyAgentRuntimeReplacementCandidate(key) {
            return true
        }
        if requiresCurrentSessionMatch,
           let panelId,
           let binding = authoritativeAgentRuntimeBinding(panelId: panelId),
           let statusKey = binding.agentRuntimeStatusKey,
           agentStatusKey(forAgentPIDKey: key, panelId: panelId) == statusKey {
            return false
        }
        return Self.structuredAgentHookStatusKeys.contains(
            agentStatusKey(forAgentPIDKey: key, panelId: panelId)
        )
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        requireOwnedKey: Bool = false,
        agentStatusKeyOverride: String? = nil,
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
        let resolvedStatusKey = agentStatusKeyOverride
            ?? agentStatusKey(forAgentPIDKey: key, panelId: lifecyclePanelId)
        let currentBinding = lifecyclePanelId.flatMap {
            authoritativeAgentRuntimeBinding(panelId: $0)
        }
        let protectsCurrentBinding = currentBinding?.agentRuntimeStatusKey == resolvedStatusKey
            && currentBinding?.matchesExactAgentRuntimeKey(key) != true
            && key != resolvedStatusKey
        let protectsCurrentAuthority = lifecyclePanelId.map {
            restoredAgentLifecycle.protectsCurrentAgentRuntimeStatus(
                resolvedStatusKey,
                clearingKey: key,
                panelId: $0
            )
        } == true
        let protectsCurrentRuntime = protectsCurrentBinding || protectsCurrentAuthority
        let statusKeyToClear = clearStatus ? resolvedStatusKey : nil

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
        if !protectsCurrentRuntime,
           let lifecyclePanelId,
           !hasAgentRuntime(
               forStatusKey: resolvedStatusKey,
               onPanel: lifecyclePanelId
           ) {
            if clearAgentLifecycle(key: resolvedStatusKey, panelId: lifecyclePanelId) {
                didChange = true
            }
        }
        if let statusKeyToClear,
           !protectsCurrentRuntime,
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
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
    }

    func refreshTrackedAgentPorts() {
        // Preserve the published snapshot until PortScanner reconciles the new
        // process tree; eagerly clearing here made every PID refresh flicker.
        let remainingAgentRoots = Set(agentPIDs.compactMap { key, pid -> AgentPortRootIdentity? in
            guard pid > 0,
                  agentPIDPanelIdsByKey[key].map({
                      !agentRuntimeUsesRemoteProcessNamespace(panelId: $0)
                  }) ?? true else {
                return nil
            }
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
        treatsPIDsAsRemote: Bool = false
    ) {
        guard let runtimeState else { return }
        for (statusKey, statusEntry) in runtimeState.statusEntries {
            statusEntries[statusKey] = statusEntry
        }
        var didAdoptAgentPID = false
        if treatsPIDsAsRemote {
            for key in runtimeState.agentPIDKeys {
                recordAgentPIDOwnership(key: key, panelId: runtimeState.panelId)
            }
        } else {
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
        restoredAgentLifecycle.clearAgentRuntimeReplacementTracking(panelId: panelId)
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
