import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation

extension DockSplitStore {
    func clearSessionRestoreState(panelId: UUID) {
        discardPendingTerminalTitleUpdate(panelId: panelId)
        removeDeferredAgentResumeRestore(panelId: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
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
        if let deferredRestore = detached.deferredAgentResumeRestore {
            deferAgentResumeRestore(
                panelId: detached.panelId,
                restore: deferredRestore
            )
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
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) { runtime in
            if Self.isStructuredAgentHookPIDKey(key, runtime: runtime) {
                let staleKeys = runtime.agentPIDKeys.filter {
                    $0 != key && Self.isStructuredAgentHookPIDKey($0, runtime: runtime)
                }
                for staleKey in staleKeys {
                    Self.clearAgentPID(
                        key: staleKey,
                        clearStatus: true,
                        runtime: &runtime
                    )
                }
                didReplaceRuntime = !staleKeys.isEmpty
            }
            runtime.agentPIDs[key] = pid
            if let identity = Workspace.agentPIDProcessIdentity(pid: pid) {
                runtime.agentPIDProcessIdentities[key] = identity
            } else {
                runtime.agentPIDProcessIdentities.removeValue(forKey: key)
            }
            runtime.agentPIDKeys.insert(key)
        }
        return didReplaceRuntime
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
        runtime: inout Workspace.DetachedAgentRuntimeState
    ) -> Bool {
        let statusKey = agentStatusKey(forAgentPIDKey: key, runtime: runtime)
        var didChange = false
        if runtime.agentPIDs.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDProcessIdentities.removeValue(forKey: key) != nil { didChange = true }
        if runtime.agentPIDKeys.remove(key) != nil { didChange = true }
        if runtime.agentLifecycleStates.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        if clearStatus,
           !runtime.agentPIDKeys.contains(where: {
               agentStatusKey(forAgentPIDKey: $0, runtime: runtime) == statusKey
           }),
           runtime.statusEntries.removeValue(forKey: statusKey) != nil {
            didChange = true
        }
        return didChange
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

extension DockSplitStore {
    /// Defers one Dock restore launch until the off-main shared agent index is ready.
    func deferAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) {
        deferredAgentResumeRestoresByPanelId[panelId] = restore
        guard deferredAgentResumeIndexTask == nil else { return }
        deferredAgentResumeIndexTask = Task { @MainActor [weak self] in
            let index = await SharedLiveAgentIndex.shared.indexRefreshingNow()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.deferredAgentResumeIndexTask = nil
            guard let index else {
                self.clearDeferredAgentResumeRestores()
                return
            }
            self.resolveDeferredAgentResumeRestores(using: index)
        }
    }

    private func resolveDeferredAgentResumeRestores(
        using index: RestorableAgentSessionIndex
    ) {
        let policy = Workspace.makeSessionRestorePolicyService()
        for (panelId, restore) in Array(deferredAgentResumeRestoresByPanelId) {
            // Explicit input can cancel the staged record while this snapshot
            // is being iterated. Never resurrect a cancelled command.
            guard deferredAgentResumeRestoresByPanelId[panelId] != nil else {
                continue
            }
            guard let terminal = panels[panelId] as? TerminalPanel else {
                removeDeferredAgentResumeRestore(panelId: panelId)
                continue
            }
            guard AgentSessionAutoResumeSettings.isEnabled(
                defaults: agentSessionAutoResumeDefaults
            ) else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            guard index.isComplete else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            guard deferredAgentResumeRestoreMatchesCurrentSession(
                panelId: panelId,
                restore: restore
            ) else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            let ownershipPanelID = restore.stablePanelID
            let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind
            let expectedSessionId = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId
            // Deferred admission has no exact-owner snapshot that can override a
            // stable-panel tie, so structural ambiguity remains fail-closed even
            // after the old owners' PIDs have exited.
            let ownershipIsBlocked = index.hasAmbiguousPanel(ownershipPanelID) ||
                index.hasCurrentAmbiguousPanel(
                    ownershipPanelID,
                    revalidateProcessEvidence: false
                ) ||
                index.hasUncertainStablePanelEntry(
                    panelId: ownershipPanelID,
                    revalidateProcessEvidence: false
                ) ||
                index.hasConflictingLiveStablePanelEntry(
                    workspaceId: workspaceId,
                    panelId: ownershipPanelID,
                    expectedKind: expectedKind,
                    expectedSessionId: expectedSessionId,
                    revalidateProcessEvidence: false
                ) ||
                index.hasCurrentLiveProcessForStablePanel(
                    workspaceId: workspaceId,
                    panelId: ownershipPanelID,
                    revalidateProcessEvidence: false
                )
            guard !ownershipIsBlocked else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }

            let startupInput: String?
            let claim: (kind: String, sessionId: String)?
            if let restorableAgent = restore.restorableAgent {
                startupInput = if restore.restoresRemoteWorkspaceTerminalSnapshot {
                    restorableAgent.resumeStartupInput(
                        useLocalRestoreVerb: false,
                        restoringWorkingDirectory: restore.resumeWorkingDirectory
                    )
                } else {
                    restorableAgent.resumeStartupInput(
                        restoringWorkingDirectory: restore.resumeWorkingDirectory
                    )
                }
                claim = (restorableAgent.kind.rawValue, restorableAgent.sessionId)
            } else if let binding = restore.resumeBinding {
                let approvedBinding = policy.approvedSurfaceResumeBinding(
                    binding,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                        defaults: agentSessionAutoResumeDefaults
                    ),
                    promptForApproval: true,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                startupInput = approvedBinding.flatMap {
                    policy.surfaceResumeStartupLaunch(forApprovedBinding: $0)?.initialInput
                }
                claim = binding.kind.flatMap { kind in
                    binding.checkpointId.map { (kind, $0) }
                }
            } else {
                startupInput = nil
                claim = nil
            }
            guard let startupInput, !startupInput.isEmpty else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let claim,
               !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                   kind: claim.kind,
                   sessionId: claim.sessionId
               ) {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let claim {
                deferredAgentResumeClaimsByPanelId[panelId] = claim
            }
            if let restoreWorkingDirectory = restore.resumeWorkingDirectory {
                restoredResumeSessionWorkingDirectoriesByPanelId[panelId] = restoreWorkingDirectory
            }
            restoredAgentLifecycle.setResumeState(
                .awaitingAutoResumeCommand,
                panelId: panelId
            )
            let admitted = terminal.surface.admitStartupRestoreRuntime(
                initialInput: startupInput
            )
            if !admitted {
                if let claim {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                        kind: claim.kind,
                        sessionId: claim.sessionId
                    )
                }
                deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                if restore.restorableAgent != nil {
                    restoredAgentLifecycle.setResumeState(
                        .manualResumeAvailable,
                        panelId: panelId
                    )
                } else {
                    restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
                }
            } else {
                terminalStartupRestoreCoordinator.recordDeferredResumeIntent(
                    panelID: panelId,
                    snapshot: restore.restorableAgent,
                    resumeBinding: restore.resumeBinding,
                    workingDirectory: restore.resumeWorkingDirectory ?? restore.workingDirectory
                )
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                if let claim,
                   let pendingClaim = deferredAgentResumeClaimsByPanelId[panelId],
                   pendingClaim.kind == claim.kind,
                   pendingClaim.sessionId == claim.sessionId {
                    // After admission the guard's bounded TTL owns this claim;
                    // do not let later panel teardown release a newer claimant.
                    deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                }
            }
        }
    }

    func removeDeferredAgentResumeRestore(panelId: UUID) {
        deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
        if let claim = deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId) {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: claim.kind,
                sessionId: claim.sessionId
            )
        }
    }

    func cancelDeferredAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore,
        startRuntime: Bool = true
    ) {
        if startRuntime {
            (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
        } else {
            terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(panelID: panelId)
            restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        }
        removeDeferredAgentResumeRestore(panelId: panelId)
        if startRuntime, restore.restorableAgent == nil {
            if let binding = restore.resumeBinding {
                retireAgentHookResumeBinding(panelId: panelId, matching: binding)
            }
        }
        if startRuntime {
            restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)
        }
    }

    private func deferredAgentResumeRestoreMatchesCurrentSession(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) -> Bool {
        guard let currentRestore = deferredAgentResumeRestoresByPanelId[panelId],
              currentRestore.stablePanelID == restore.stablePanelID,
              let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind,
              let expectedSessionID = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId else {
            return false
        }
        let currentSnapshot = restoredAgentLifecycle.snapshotsByPanelId[panelId]
            ?? terminalStartupRestoreCoordinator.stagedSnapshot(panelID: panelId)
        if let currentSnapshot {
            guard currentSnapshot.kind.rawValue == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSnapshot.sessionId,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        } else if restore.restorableAgent != nil {
            return false
        }

        if restore.resumeBinding != nil {
            guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
                  let currentKind = currentBinding.kind,
                  let currentSessionID = currentBinding.checkpointId,
                  currentKind == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSessionID,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        } else if let currentBinding = surfaceResumeBindingsByPanelId[panelId] {
            guard let currentKind = currentBinding.kind,
                  let currentSessionID = currentBinding.checkpointId,
                  currentKind == expectedKind,
                  ManagedAgentSessionIdentity.sessionIDsMatch(
                      kind: expectedKind,
                      lhs: currentSessionID,
                      rhs: expectedSessionID
                  ) else {
                return false
            }
        }
        return true
    }

    private func retireAgentHookResumeBinding(
        panelId: UUID,
        matching binding: SurfaceResumeBindingSnapshot
    ) {
        guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
              currentBinding.isAgentHookBinding,
              currentBinding == binding || currentBinding.isSameManagedSession(as: binding) else {
            return
        }
        retireAgentHookResumeBinding(panelId: panelId)
    }

    func clearDeferredAgentResumeRestores(startRuntime: Bool = true) {
        deferredAgentResumeIndexTask?.cancel()
        deferredAgentResumeIndexTask = nil
        let panelIds = Set(
            Array(deferredAgentResumeRestoresByPanelId.keys)
                + Array(deferredAgentResumeClaimsByPanelId.keys)
        )
        for panelId in panelIds {
            if let restore = deferredAgentResumeRestoresByPanelId[panelId] {
                cancelDeferredAgentResumeRestore(
                    panelId: panelId,
                    restore: restore,
                    startRuntime: startRuntime
                )
            } else {
                if startRuntime {
                    (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
                } else {
                    terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(panelID: panelId)
                    restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
                }
                removeDeferredAgentResumeRestore(panelId: panelId)
            }
        }
        deferredAgentResumeRestoresByPanelId.removeAll()
    }
}
