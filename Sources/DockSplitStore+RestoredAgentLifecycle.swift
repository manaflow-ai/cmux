import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation

extension DockSplitStore {
    func clearSessionRestoreState(panelId: UUID) {
        discardPendingTerminalTitleUpdate(panelId: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        if let runtime = agentRuntimeByPanelId.removeValue(forKey: panelId) {
            for key in runtime.agentPIDKeys {
                agentProcessExitMonitor.cancel(
                    key: Self.agentProcessObservationKey(
                        key: key,
                        panelId: panelId
                    )
                )
            }
        }
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
        managedAgentResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        if let resumeBinding = detached.resumeBinding {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        }
        if let transferredManagedBinding = detached.resolvedManagedAgentResumeBinding {
            managedAgentResumeBindingsByPanelId[detached.panelId] = transferredManagedBinding
        }
        if let directory = detached.restoredResumeSessionWorkingDirectory {
            restoredResumeSessionWorkingDirectoriesByPanelId[detached.panelId] = directory
        }
        if var runtime = detached.agentRuntime {
            if let previous = agentRuntimeByPanelId[detached.panelId] {
                for key in previous.agentPIDKeys {
                    agentProcessExitMonitor.cancel(
                        key: Self.agentProcessObservationKey(
                            key: key,
                            panelId: detached.panelId
                        )
                    )
                }
            }
            Self.seedAgentLifecycleReconciliationIfNeeded(
                runtime: &runtime,
                panelId: detached.panelId
            )
            runtime.agentLifecycleStates =
                runtime.agentLifecycleReconciliationState
                    .resolvedStatesByPanelId[detached.panelId] ?? [:]
            agentRuntimeByPanelId[detached.panelId] = runtime
            if !detached.isRemoteTerminal {
                for (key, generation) in runtime.agentPIDProcessIdentities {
                    guard runtime.agentPIDs[key] == generation.pid,
                          Workspace.agentPIDProcessIdentity(
                              pid: generation.pid
                          ) == generation else {
                        _ = clearAgentPID(
                            key: key,
                            panelId: detached.panelId,
                            clearStatus: true
                        )
                        continue
                    }
                    observeAgentProcessExit(
                        key: key,
                        panelId: detached.panelId,
                        generation: generation
                    )
                }
            }
        } else {
            if let previous =
                agentRuntimeByPanelId.removeValue(forKey: detached.panelId) {
                for key in previous.agentPIDKeys {
                    agentProcessExitMonitor.cancel(
                        key: Self.agentProcessObservationKey(
                            key: key,
                            panelId: detached.panelId
                        )
                    )
                }
            }
        }
        syncAgentNeedsInputAttention(
            panelId: detached.panelId,
            runtime: agentRuntimeByPanelId[detached.panelId]
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

    func agentRuntimeLifecycleState(
        key: String,
        panelId: UUID
    ) -> AgentHibernationLifecycleState? {
        agentRuntimeByPanelId[panelId]?.agentLifecycleStates[key]
    }

    func hasLiveAgentProcess(
        statusKey: String,
        panelId: UUID,
        matching requiredGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        guard let runtime = agentRuntimeByPanelId[panelId] else {
            return false
        }
        return runtime.agentPIDKeys.contains { pidKey in
            guard Self.agentStatusKey(
                forAgentPIDKey: pidKey,
                runtime: runtime
            ) == statusKey,
            let pid = runtime.agentPIDs[pidKey],
            let recordedIdentity =
                runtime.agentPIDProcessIdentities[pidKey],
            recordedIdentity.pid == pid,
            requiredGeneration == nil
                || recordedIdentity == requiredGeneration else {
                return false
            }
            return Workspace.agentPIDProcessIdentity(pid: pid)
                == recordedIdentity
        }
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
    func recordAgentPID(
        key: String,
        pid: pid_t,
        panelId: UUID,
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        observeProcessExit: Bool = true
    ) -> Bool {
        recordAgentPIDResult(
            key: key,
            pid: pid,
            panelId: panelId,
            processIdentity: providedProcessIdentity,
            observeProcessExit: observeProcessExit
        ).replacedOtherRuntime
    }

    /// Admits an exact process generation before replacing any Dock runtime.
    func recordAgentPIDResult(
        key: String,
        pid: pid_t,
        panelId: UUID,
        processIdentity providedProcessIdentity:
            AgentPIDProcessIdentity? = nil,
        observeProcessExit: Bool = true
    ) -> (accepted: Bool, replacedOtherRuntime: Bool) {
        var didReplaceRuntime = false
        var didReplaceProcessGeneration = false
        var accepted = false
        let processIdentity =
            providedProcessIdentity
                ?? Workspace.agentPIDProcessIdentity(pid: pid)
        if let processIdentity,
           let runtime = agentRuntimeByPanelId[panelId],
           runtime.agentPIDs[key] == pid,
           runtime.agentPIDProcessIdentities[key] == processIdentity,
           runtime.agentPIDKeys.contains(key) {
            return (accepted: true, replacedOtherRuntime: false)
        }
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            let statusKey = Self.agentStatusKey(
                forAgentPIDKey: key,
                runtime: runtime
            )
            if let processIdentity {
                if let previousGeneration =
                    runtime.agentPIDProcessIdentities[key],
                   processIdentity < previousGeneration {
                    return
                }
                guard runtime.agentLifecycleReconciliationState
                    .recordProcessGeneration(
                        key: statusKey,
                        panelId: panelId,
                        generation: processIdentity,
                        isBuiltIn: AgentHibernationLifecycleStatusKeys(
                            rawValue: statusKey
                        ).isAllowed
                    ) else {
                    return
                }
            }
            accepted = true
            if let previousGeneration =
                runtime.agentPIDProcessIdentities[key],
               previousGeneration != processIdentity {
                didReplaceProcessGeneration = true
                _ = runtime.agentLifecycleReconciliationState
                    .recordProcessExit(
                        key: statusKey,
                        panelId: panelId,
                        generation: previousGeneration
                    )
                let hasOtherRuntime = runtime.agentPIDKeys.contains {
                    $0 != key
                        && Self.agentStatusKey(
                            forAgentPIDKey: $0,
                            runtime: runtime
                        ) == statusKey
                }
                if !hasOtherRuntime {
                    runtime.statusEntries.removeValue(forKey: statusKey)
                }
            }
            if Self.isStructuredAgentHookPIDKey(key, runtime: runtime) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    guard $0 != key,
                          Self.isStructuredAgentHookPIDKey(
                              $0,
                              runtime: runtime
                          ) else {
                        return false
                    }
                    return Self.agentStatusKey(
                        forAgentPIDKey: $0,
                        runtime: runtime
                    ) != statusKey
                        || processIdentity == nil
                        || runtime.agentPIDProcessIdentities[$0]
                            != processIdentity
                }
                for staleKey in staleKeys {
                    agentProcessExitMonitor.cancel(
                        key: Self.agentProcessObservationKey(
                            key: staleKey,
                            panelId: panelId
                        )
                    )
                    Self.clearAgentPID(
                        key: staleKey,
                        clearStatus: true,
                        runtime: &runtime
                    )
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            runtime.agentPIDs[key] = pid
            if let processIdentity {
                runtime.agentPIDProcessIdentities[key] = processIdentity
            } else {
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        guard accepted else {
            return (accepted: false, replacedOtherRuntime: false)
        }
        // A remote replacement must still retire any local observer that was
        // attached to the previous owner; it simply must not start a new
        // observer against the Mac process table.
        if !observeProcessExit {
            agentProcessExitMonitor.cancel(
                key: Self.agentProcessObservationKey(
                    key: key,
                    panelId: panelId
                )
            )
        }
        if observeProcessExit {
            agentProcessExitMonitor.cancel(
                key: Self.agentProcessObservationKey(
                    key: key,
                    panelId: panelId
                )
            )
            if let generation = agentRuntimeByPanelId[panelId]?
                .agentPIDProcessIdentities[key] {
                observeAgentProcessExit(
                    key: key,
                    panelId: panelId,
                    generation: generation
                )
            }
        }
        if didReplaceProcessGeneration {
            TerminalNotificationStore.shared.clearNotifications(
                forTabId: workspaceId,
                surfaceId: panelId
            )
        }
        return (
            accepted: true,
            replacedOtherRuntime: didReplaceRuntime
        )
    }

    @discardableResult
    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        var accepted = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            accepted = $0.agentLifecycleReconciliationState.setHookLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(
                    rawValue: key
                ).isAllowed,
                processGeneration: processGeneration
            )
        }
        return accepted
    }

    @discardableResult
    func clearAgentLifecycle(
        key: String,
        panelId: UUID
    ) -> Bool {
        var removed = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            removed = $0.agentLifecycleReconciliationState.removeHook(
                key: key,
                panelId: panelId
            )
        }
        if removed,
           !AgentHibernationLifecycleStatusKeys(rawValue: key).isManual {
            AgentHibernationController.shared.recordAgentLifecycleChange(
                workspaceId: workspaceId,
                panelId: panelId
            )
        }
        return removed
    }

    func beginAgentFeedAttention(
        key: String,
        panelId: UUID,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> AgentFeedAttentionToken? {
        var token: AgentFeedAttentionToken?
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            token = $0.agentLifecycleReconciliationState
                .beginFeedAttention(
                    key: key,
                    panelId: panelId,
                    isBuiltIn:
                        AgentHibernationLifecycleStatusKeys(
                            rawValue: key
                        ).isAllowed,
                    processGeneration: processGeneration
                )
        }
        return token
    }

    @discardableResult
    func endAgentFeedAttention(
        key: String,
        panelId: UUID,
        token: AgentFeedAttentionToken
    ) -> Bool {
        var ended = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            ended = $0.agentLifecycleReconciliationState
                .endFeedAttention(
                    key: key,
                    panelId: panelId,
                    token: token
                )
        }
        return ended
    }

    func recordUnidentifiedAgentProcessExit(
        key: String,
        panelId: UUID
    ) {
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            $0.agentLifecycleReconciliationState
                .recordUnidentifiedProcessExit(
                    key: key,
                    panelId: panelId,
                    isBuiltIn:
                        AgentHibernationLifecycleStatusKeys(
                            rawValue: key
                        ).isAllowed
                )
        }
    }

    @discardableResult
    func recordAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) -> Bool {
        var recorded = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            recorded = $0.agentLifecycleReconciliationState
                .recordProcessExit(
                    key: key,
                    panelId: panelId,
                    generation: generation
                )
        }
        return recorded
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
        agentProcessExitMonitor.cancel(
            key: Self.agentProcessObservationKey(
                key: key,
                panelId: panelId
            )
        )
        var didChange = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didChange = Self.clearAgentPID(
                key: key,
                clearStatus: clearStatus,
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
        Self.seedAgentLifecycleReconciliationIfNeeded(
            runtime: &runtime,
            panelId: panelId
        )
        mutation(&runtime)
        runtime.agentLifecycleStates =
            runtime.agentLifecycleReconciliationState.resolvedStatesByPanelId[panelId] ?? [:]
        let shouldKeep = !runtime.statusEntries.isEmpty
            || !runtime.agentPIDs.isEmpty
            || !runtime.agentPIDKeys.isEmpty
            || !runtime.agentLifecycleStates.isEmpty
            || runtime.agentLifecycleReconciliationState.hasEvidence
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
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        let generation = runtime.agentPIDProcessIdentities[key]
        let hadFeedAttention = runtime.agentLifecycleReconciliationState
            .hasFeedAttention(
                key: statusKey,
                panelId: runtime.panelId
            )
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        let hasRemainingStatusRuntime = runtime.agentPIDKeys.contains {
            agentStatusKey(
                forAgentPIDKey: $0,
                runtime: runtime
            ) == statusKey
        }
        let hasRemainingGenerationOwner = generation.map {
            retainedGeneration in
            runtime.agentPIDKeys.contains {
                agentStatusKey(
                    forAgentPIDKey: $0,
                    runtime: runtime
                ) == statusKey
                    && runtime.agentPIDProcessIdentities[$0]
                        == retainedGeneration
            }
        } ?? false
        let didClearLifecycle: Bool
        if let generation, !hasRemainingGenerationOwner {
            didClearLifecycle = runtime.agentLifecycleReconciliationState.recordProcessExit(
                key: statusKey,
                panelId: runtime.panelId,
                generation: generation
            )
        } else if AgentHibernationLifecycleStatusKeys(
            rawValue: statusKey
        ).isAllowed,
                  !hasRemainingStatusRuntime {
            didClearLifecycle = runtime.agentLifecycleReconciliationState
                .recordUnidentifiedProcessExit(
                    key: statusKey,
                    panelId: runtime.panelId,
                    isBuiltIn: true
                )
        } else if !hasRemainingStatusRuntime {
            didClearLifecycle = runtime.agentLifecycleReconciliationState.removeKey(
                key: statusKey,
                panelId: runtime.panelId
            )
        } else {
            didClearLifecycle = false
        }
        if didClearLifecycle {
            didChange = true
        }
        if clearStatus, runtime.statusEntries[statusKey] != nil {
            let feedAttentionStillVisible =
                runtime.agentLifecycleReconciliationState
                    .hasFeedAttention(
                        key: statusKey,
                        panelId: runtime.panelId
                    )
            if !hasRemainingStatusRuntime
                || (hadFeedAttention && !feedAttentionStillVisible) {
                runtime.statusEntries.removeValue(forKey: statusKey)
                didChange = true
            }
        }
        return didChange
    }

    private static func seedAgentLifecycleReconciliationIfNeeded(
        runtime: inout Workspace.DetachedAgentRuntimeState,
        panelId: UUID
    ) {
        guard !runtime.agentLifecycleReconciliationState.hasEvidence else {
            return
        }
        for (pidKey, generation) in runtime.agentPIDProcessIdentities {
            let statusKey = agentStatusKey(
                forAgentPIDKey: pidKey,
                runtime: runtime
            )
            runtime.agentLifecycleReconciliationState.recordProcessGeneration(
                key: statusKey,
                panelId: panelId,
                generation: generation,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(
                    rawValue: statusKey
                ).isAllowed
            )
        }
        for (key, lifecycle) in runtime.agentLifecycleStates {
            _ = runtime.agentLifecycleReconciliationState.setHookLifecycle(
                key: key,
                panelId: panelId,
                lifecycle: lifecycle,
                isBuiltIn: AgentHibernationLifecycleStatusKeys(
                    rawValue: key
                ).isAllowed
            )
        }
    }

    private func handleObservedAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) {
        guard agentRuntimeByPanelId[panelId]?.agentPIDs[key] == generation.pid,
              agentRuntimeByPanelId[panelId]?
                .agentPIDProcessIdentities[key] == generation,
              clearAgentPID(
                  key: key,
                  panelId: panelId,
                  clearStatus: true
              ) else {
            return
        }
        TerminalNotificationStore.shared.clearNotifications(
            forTabId: workspaceId,
            surfaceId: panelId
        )
    }

    private func observeAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) {
        let observationKey = Self.agentProcessObservationKey(
            key: key,
            panelId: panelId
        )
        agentProcessExitMonitor.observe(
            key: observationKey,
            generation: generation
        ) { [weak self] _, generation in
            self?.handleObservedAgentProcessExit(
                key: key,
                panelId: panelId,
                generation: generation
            )
        }
    }

    private static func agentProcessObservationKey(
        key: String,
        panelId: UUID
    ) -> String {
        "\(panelId.uuidString.lowercased()):\(key)"
    }

    private static func isStructuredAgentHookPIDKey(
        _ key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(
            agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        )
    }

    private static func agentStatusKey(
        forAgentPIDKey key: String,
        runtime: Workspace.DetachedAgentRuntimeState
    ) -> String {
        if runtime.statusEntries[key] != nil {
            return key
        }
        guard let dotIndex = key.firstIndex(of: ".") else {
            return key
        }
        return String(key[..<dotIndex])
    }
}
