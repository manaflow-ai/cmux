import CMUXAgentLaunch
import CmuxWorkspaces
import CmuxNotifications
import CmuxSidebar
import Darwin
import Foundation

extension DockSplitStore {
    func clearSessionRestoreState(panelId: UUID) {
        discardPendingTerminalTitleUpdate(panelId: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.clearAgentRuntimeReplacementTracking(panelId: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        agentRuntimeByPanelId.removeValue(forKey: panelId)
        syncAgentNeedsInputAttention(panelId: panelId, runtime: nil)
        restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard let terminal = panels[panelId] as? TerminalPanel else { return }
        flushPendingTerminalTitleUpdate(panelId: panelId)
        let previousState = terminal.shellActivity.state
        terminal.updateShellActivityState(state)
        if previousState != state,
           let pendingTitle = advanceRestoredPanelTitleBoundary(
               panelId: panelId,
               state: state
           ) {
            applyResolvedTerminalTitle(pendingTitle, to: terminal)
        }
        let restoredAgent = restoredAgentLifecycle.snapshotsByPanelId[panelId]

        switch (state, restoredAgentLifecycle.resumeStatesByPanelId[panelId]) {
        case (.commandRunning, .some(.awaitingAutoResumeCommand)):
            restoredAgentLifecycle.setResumeState(.autoResumeCommandRunning, panelId: panelId)
        case (.commandRunning, .some(.manualResumeAvailable)):
            restoredAgentLifecycle.setSnapshot(nil, panelId: panelId)
            restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
            retireAgentHookResumeBinding(panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            if restoredAgent != nil {
                markRestoredAgentCompleted(panelId: panelId)
            } else {
                restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
            }
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            retireAgentHookResumeBinding(panelId: panelId, matching: restoredAgent)
        default:
            break
        }
        if state == .promptIdle {
            clearRemoteAgentRuntime(panelId: panelId)
        }
    }

    /// Consumes structured remote-agent runtime after its prompt or terminal
    /// lifecycle ends, without touching unrelated panel runtime state.
    func clearRemoteAgentRuntime(panelId: UUID) {
        guard detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal == true else {
            return
        }
        guard let binding = authoritativeAgentRuntimeBinding(panelId: panelId) else {
            return
        }
        clearAgentRuntimeOwned(by: binding, panelId: panelId)
    }

    /// Returns active or eligible-retired authority, falling back to cached
    /// transfer metadata only while that cache remains valid.
    func authoritativeAgentRuntimeBinding(
        panelId: UUID
    ) -> SurfaceResumeBindingSnapshot? {
        if let binding = managedAgentResumeBinding(panelId: panelId) {
            return binding
        }
        if let binding = restoredAgentLifecycle
            .eligibleRetiredAgentRuntimeBinding(panelId: panelId) {
            return binding
        }
        guard !invalidatedCachedTransferAgentSessionPanelIds.contains(panelId),
              !replacedCachedTransferAgentSessionPanelIds.contains(panelId) else {
            return nil
        }
        return detachedSurfaceTransfersByPanelId[panelId]?
            .resolvedManagedAgentResumeBinding
    }

    /// Clears only runtime state whose kind-scoped key belongs to `binding`.
    func clearAgentRuntimeOwned(
        by binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        guard let statusKey = binding.agentRuntimeStatusKey else { return }
        mutateAgentRuntime(panelId: panelId) { runtime in
            let keys = runtime.agentPIDKeys.filter {
                binding.matchesAgentRuntimeKeyForCleanup($0)
            }
            for key in keys {
                Self.clearAgentPID(
                    key: key,
                    clearStatus: true,
                    statusKeyOverride: statusKey,
                    managedBinding: binding,
                    runtime: &runtime
                )
            }
            runtime.agentLifecycleStates.removeValue(forKey: statusKey)
            if !runtime.agentPIDKeys.contains(where: {
                binding.matchesAgentRuntimeKeyForCleanup($0)
            }) {
                runtime.statusEntries.removeValue(forKey: statusKey)
            }
        }
    }

    /// Starts title admission for a terminal rebuilt directly inside this Dock.
    func armRestoredPanelTitleBoundary(
        panelId: UUID,
        internallySeededInput: String?
    ) {
        let boundary = RestoredPanelTitleBoundary(
            internallySeededInput: internallySeededInput,
            shellState: (panels[panelId] as? TerminalPanel)?.shellActivity.state
                ?? .unknown
        )
        storeRestoredPanelTitleBoundary(
            boundary.isReleased ? nil : boundary,
            panelId: panelId
        )
    }

    /// Advances either a Dock-owned boundary or one carried by a transferred panel.
    private func advanceRestoredPanelTitleBoundary(
        panelId: UUID,
        state: PanelShellActivityState
    ) -> String? {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return nil
        }
        let pendingTitle = boundary.observe(shellState: state)
        storeRestoredPanelTitleBoundary(
            boundary.isReleased ? nil : boundary,
            panelId: panelId
        )
        return pendingTitle
    }

    /// Returns whether a normalized raw PTY title crossed the active restore boundary.
    func shouldApplyRestoredPanelTitle(panelId: UUID, rawTitle: String) -> Bool {
        guard var boundary = restoredPanelTitleBoundariesByPanelId[panelId] else {
            return true
        }
        let shouldApply = boundary.shouldApply(rawTitle: rawTitle)
        storeRestoredPanelTitleBoundary(
            boundary.isReleased ? nil : boundary,
            panelId: panelId
        )
        return shouldApply
    }

    private func storeRestoredPanelTitleBoundary(
        _ boundary: RestoredPanelTitleBoundary?,
        panelId: UUID
    ) {
        if let boundary {
            restoredPanelTitleBoundariesByPanelId[panelId] = boundary
        } else {
            restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        }
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId] else {
            return
        }
        transfer.restoredPanelTitleBoundary = boundary
        setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
    }

    func adoptSessionRestoreState(from detached: Workspace.DetachedSurfaceTransfer) {
        invalidatedCachedTransferAgentSessionPanelIds.remove(detached.panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(detached.panelId)
        storeRestoredPanelTitleBoundary(
            detached.restoredPanelTitleBoundary,
            panelId: detached.panelId
        )
        if let shellActivityState = detached.shellActivityState {
            (detached.panel as? TerminalPanel)?.updateShellActivityState(
                shellActivityState
            )
        }
        restoredAgentLifecycle.seedTransferredState(
            panelId: detached.panelId,
            snapshot: detached.restorableAgent,
            resumeState: detached.restorableAgentResumeState,
            completedGeneration: detached.restoredAgentCompletedGeneration,
            resumeWorkingDirectory: detached.restoredResumeSessionWorkingDirectory
        )
        restoredAgentLifecycle.seedAgentRuntimeReplacementTracking(
            detached.agentRuntimeReplacementTracking,
            panelId: detached.panelId
        )
        managedAgentResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        if let resumeBinding = detached.resumeBinding {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        }
        if let transferredManagedBinding = detached.resolvedManagedAgentResumeBinding {
            managedAgentResumeBindingsByPanelId[detached.panelId] = transferredManagedBinding
            if transferredManagedBinding.isAgentHookBinding {
                restoredAgentLifecycle.activateAgentRuntimeBinding(
                    transferredManagedBinding,
                    panelId: detached.panelId
                )
            }
        }
        if let runtime = detached.agentRuntime {
            agentRuntimeByPanelId[detached.panelId] = runtime
        } else {
            agentRuntimeByPanelId.removeValue(forKey: detached.panelId)
        }
        syncAgentNeedsInputAttention(
            panelId: detached.panelId,
            runtime: detached.agentRuntime
        )
    }

    func configureAgentHibernationResume(for terminal: TerminalPanel) {
        terminal.onRequestAgentHibernationResume = { [weak self, weak terminal] focus in
            guard let self, let terminal else { return false }
            return self.resumeAgentHibernation(panelId: terminal.id, focus: focus)
        }
    }

    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let terminal = panels[panelId] as? TerminalPanel,
              terminal.isAgentHibernated else {
            return false
        }
        let preparation = terminal.prepareAgentHibernationResume()
        guard preparation.didResume else { return false }
        if restoredAgentLifecycle.snapshotsByPanelId[panelId] != nil {
            restoredAgentLifecycle.setResumeState(
                preparation.queuedStartupInput
                    ? .awaitingAutoResumeCommand
                    : .manualResumeAvailable,
                panelId: panelId
            )
            restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        AgentHibernationController.shared.recordTerminalFocus(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if focus { focusPanel(panelId) }
        return true
    }

    private func retireAgentHookResumeBinding(
        panelId: UUID,
        matching restoredAgent: SessionRestorableAgentSnapshot? = nil
    ) {
        guard var binding = managedAgentResumeBinding(panelId: panelId)
            ?? surfaceResumeBindingsByPanelId[panelId],
            binding.isAgentHookBinding else {
            return
        }
        if let restoredAgent {
            let checkpointId = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard checkpointId == nil || checkpointId == restoredAgent.sessionId else {
                return
            }
        }
        let originalBinding = binding
        binding.autoResume = false
        if binding.hasCompleteManagedSessionIdentity {
            managedAgentResumeBindingsByPanelId[panelId] = binding
        }
        if let effectiveBinding = surfaceResumeBindingsByPanelId[panelId] {
            if effectiveBinding == originalBinding || effectiveBinding.isSameManagedSession(as: binding) {
                surfaceResumeBindingsByPanelId[panelId] = binding
            }
        } else {
            surfaceResumeBindingsByPanelId[panelId] = binding
        }
    }

    func markRestoredAgentCompleted(panelId: UUID) {
        // A live completion belongs to the current session generation. Keep
        // older cached metadata invalidated, but no longer classify this
        // current tombstone as the cached generation that was replaced.
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        let runtimeIdentities = Set(
            (agentRuntimeByPanelId[panelId]
                ?? detachedSurfaceTransfersByPanelId[panelId]?.agentRuntime)?
                .agentPIDProcessIdentities.values.map { $0 } ?? []
        )
        restoredAgentLifecycle.markCompleted(
            panelId: panelId,
            observation: SharedLiveAgentIndex.shared.index?.entry(
                workspaceId: detachedSurfaceTransfersByPanelId[panelId]?.sessionRestoreWorkspaceId
                    ?? workspaceId,
                panelId: panelId
            ),
            runtimeProcessIdentities: runtimeIdentities
        )
    }

    func agentRuntimeStatusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
        agentRuntimeByPanelId[panelId]?.statusEntries[key]
    }

    func setAgentRuntimeStatusEntry(
        _ entry: SidebarStatusEntry,
        key: String,
        panelId: UUID
    ) {
        mutateAgentRuntime(panelId: panelId) {
            $0.statusEntries[key] = entry
        }
    }

    func clearAgentRuntimeStatusEntry(key: String, panelId: UUID) {
        mutateAgentRuntime(panelId: panelId) {
            $0.statusEntries.removeValue(forKey: key)
        }
    }

    @discardableResult
    func recordAgentPID(key: String, pid: pid_t, panelId: UUID) -> Bool {
        var didReplaceRuntime = false
        let storesLocalProcess = detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal != true
        let managedBinding = authoritativeAgentRuntimeBinding(panelId: panelId)
        let lifecycle = restoredAgentLifecycle
        if managedBinding?.rejectsMismatchedAgentRuntimeKey(key) == true
            || restoredAgentLifecycle.rejectsSupersededAgentRuntimeKey(
                key,
                panelId: panelId
            ) {
            return false
        }
        let recordsCurrentBinding = managedBinding?.matchesExactAgentRuntimeKey(key) == true
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            if Self.isStructuredAgentHookPIDKey(
                key,
                runtime: runtime,
                managedBinding: managedBinding
            ) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    $0 != key && Self.isStructuredAgentHookPIDKey(
                        $0,
                        runtime: runtime,
                        managedBinding: managedBinding
                    ) && !(managedBinding?.matchesExactAgentRuntimeKey(key) == true
                        && managedBinding?.matchesExactAgentRuntimeKey($0) == true)
                }
                for staleKey in staleKeys {
                    Self.clearAgentPID(
                        key: staleKey,
                        clearStatus: true,
                        managedBinding: managedBinding,
                        protectsCurrentRuntimeStatus: { statusKey, clearingKey in
                            lifecycle.protectsCurrentAgentRuntimeStatus(
                                statusKey,
                                clearingKey: clearingKey,
                                panelId: panelId
                            )
                        },
                        runtime: &runtime
                    )
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            if storesLocalProcess {
                runtime.agentPIDs[key] = pid
                if let identity = Workspace.agentPIDProcessIdentity(pid: pid) {
                    runtime.agentPIDProcessIdentities[key] = identity
                } else {
                    runtime.agentPIDProcessIdentities.removeValue(forKey: key)
                }
            } else {
                runtime.agentPIDs.removeValue(forKey: key)
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        let carriesBindingReplacement = recordsCurrentBinding
            && managedBinding.map {
                restoredAgentLifecycle.consumePendingAgentRuntimeReplacement(
                    for: $0,
                    panelId: panelId
                )
            } == true
        return didReplaceRuntime || carriesBindingReplacement
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            $0.agentLifecycleStates[key] = lifecycle
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID) -> Bool {
        var didClear = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didClear = $0.agentLifecycleStates.removeValue(forKey: key) != nil
        }
        return didClear
    }

    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID,
        clearStatus: Bool,
        requireOwnedKey: Bool = false
    ) -> Bool {
        if requireOwnedKey,
           agentRuntimeByPanelId[panelId]?.agentPIDKeys.contains(key) != true {
            return false
        }
        var didChange = false
        let managedBinding = authoritativeAgentRuntimeBinding(panelId: panelId)
        let lifecycle = restoredAgentLifecycle
        let retiredStatusKeyForRuntimeKey: (String) -> String? = { runtimeKey in
            lifecycle.retiredAgentRuntimeStatusKey(
                for: runtimeKey,
                panelId: panelId
            )
        }
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
                managedBinding: managedBinding,
                retiredStatusKeyForRuntimeKey: retiredStatusKeyForRuntimeKey,
                protectsCurrentRuntimeStatus: { statusKey, clearingKey in
                    lifecycle.protectsCurrentAgentRuntimeStatus(
                        statusKey,
                        clearingKey: clearingKey,
                        panelId: panelId
                    )
                },
                runtime: &$0
            )
        }
        return didChange
    }

    private func mutateAgentRuntime(
        panelId: UUID,
        updatesAgentAttention: Bool = false,
        mutation: (inout Workspace.DetachedAgentRuntimeState) -> Void
    ) {
        guard panels[panelId] != nil else { return }
        var runtime = agentRuntimeByPanelId[panelId] ?? Workspace.DetachedAgentRuntimeState(
            panelId: panelId,
            statusEntries: [:],
            agentPIDs: [:],
            agentPIDProcessIdentities: [:],
            agentPIDKeys: []
        )
        mutation(&runtime)
        let shouldKeep = !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
        if shouldKeep {
            agentRuntimeByPanelId[panelId] = runtime
        } else {
            agentRuntimeByPanelId.removeValue(forKey: panelId)
        }
        if var transfer = detachedSurfaceTransfersByPanelId[panelId] {
            transfer.agentRuntime = shouldKeep ? runtime : nil
            detachedSurfaceTransfersByPanelId[panelId] = transfer
        }
        if updatesAgentAttention {
            syncAgentNeedsInputAttention(
                panelId: panelId,
                runtime: shouldKeep ? runtime : nil
            )
        }
    }

    private func syncAgentNeedsInputAttention(
        panelId: UUID,
        runtime: Workspace.DetachedAgentRuntimeState?
    ) {
        let needsInput = runtime?.agentLifecycleStates.values.contains(.needsInput) == true
        agentNeedsInputAttention.setAttention(needsInput, forSurfaceId: panelId)
    }

    @discardableResult
    private static func clearAgentPID(
        key: String,
        clearStatus: Bool,
        statusKeyOverride: String? = nil,
        managedBinding: SurfaceResumeBindingSnapshot? = nil,
        retiredStatusKeyForRuntimeKey: (String) -> String? = { _ in nil },
        protectsCurrentRuntimeStatus: (String, String) -> Bool = { _, _ in false },
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = statusKeyOverride ?? agentStatusKey(
            forAgentPIDKey: key,
            runtime: runtime,
            managedBinding: managedBinding,
            retiredStatusKey: retiredStatusKeyForRuntimeKey(key)
        )
        let protectsCurrentBinding = managedBinding?.agentRuntimeStatusKey == statusKey
            && managedBinding?.matchesExactAgentRuntimeKey(key) != true
            && key != statusKey
        let protectsCurrentAuthority = protectsCurrentRuntimeStatus(statusKey, key)
        let protectsCurrentRuntime = protectsCurrentBinding || protectsCurrentAuthority
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        let hasRemainingRuntime = runtime.agentPIDKeys.contains {
            agentStatusKey(
                forAgentPIDKey: $0,
                runtime: runtime,
                managedBinding: managedBinding,
                retiredStatusKey: retiredStatusKeyForRuntimeKey($0)
            ) == statusKey
        }
        if !protectsCurrentRuntime,
           !hasRemainingRuntime,
           runtime.agentLifecycleStates.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if clearStatus,
           !protectsCurrentRuntime,
           !hasRemainingRuntime,
           runtime.statusEntries.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        return didChange
    }

    private static func isStructuredAgentHookPIDKey(
        _ key: String,
        runtime: Workspace.DetachedAgentRuntimeState,
        managedBinding: SurfaceResumeBindingSnapshot?
    ) -> Bool {
        if AgentRuntimeSessionKey(rawValue: key) != nil {
            return true
        }
        if let managedBinding,
           managedBinding.matchesAgentRuntimeKeyForCleanup(key) {
            return managedBinding.matchesExactAgentRuntimeKey(key)
        }
        if let managedBinding,
           managedBinding.isLegacyAgentRuntimeReplacementCandidate(key) {
            return true
        }
        if let managedBinding,
           let statusKey = managedBinding.agentRuntimeStatusKey,
           agentStatusKey(
               forAgentPIDKey: key,
               runtime: runtime,
               managedBinding: managedBinding
           ) == statusKey {
            return false
        }
        return AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(
            agentStatusKey(
                forAgentPIDKey: key,
                runtime: runtime,
                managedBinding: managedBinding
            )
        )
    }

    private static func agentStatusKey(
        forAgentPIDKey key: String,
        runtime: Workspace.DetachedAgentRuntimeState,
        managedBinding: SurfaceResumeBindingSnapshot? = nil,
        retiredStatusKey: String? = nil
    ) -> String {
        if let structuredKey = AgentRuntimeSessionKey(rawValue: key) {
            return structuredKey.statusKey
        }
        if let managedBinding,
           let statusKey = managedBinding.agentRuntimeStatusKey,
           managedBinding.matchesAgentRuntimeKeyForCleanup(key) {
            return statusKey
        }
        if let retiredStatusKey {
            return retiredStatusKey
        }
        if runtime.statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }
}
