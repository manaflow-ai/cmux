import CmuxTerminalCore
import CmuxNotifications
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import AppKit
import Foundation
extension DockSplitStore {
    func clearSessionRestoreState(panelId: UUID) {
        discardPendingTerminalTitleUpdate(panelId: panelId)
        removeDeferredAgentResumeRestore(panelId: panelId)
        restoredAgentLifecycle.clearStartupInput(panelId: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
        replacedCachedTransferAgentSessionPanelIds.remove(panelId)
        agentRuntimeByPanelId.removeValue(forKey: panelId)
        syncAgentNeedsInputAttention(panelId: panelId, runtime: nil)
        restoredPanelTitleBoundariesByPanelId.removeValue(forKey: panelId)
        panelCustomTitleSourcesByPanelId.removeValue(forKey: panelId)
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard let terminal = panels[panelId] as? TerminalPanel else { return }
        flushPendingTerminalTitleUpdate(panelId: panelId)
        let previousState = terminal.shellActivity.state
        terminal.updateShellActivityState(state)
        // A transferred terminal can already report promptIdle before the
        // destination receives its first prompt marker. Replaying that
        // idempotent marker is still meaningful to the restore boundary: it
        // clears any buffered pre-transfer title before commandRunning can
        // release it as if it came from a new user command.
        if (previousState != state || state == .promptIdle),
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
            restoredAgentLifecycle.clearStartupInput(panelId: panelId)
        case (.commandRunning, .some(.manualResumeAvailable)):
            if restoredAgentHasLiveProcess(panelId: panelId, restoredAgent: restoredAgent) {
                // A TUI turn (OSC 133;C) from the agent itself, not an
                // unrelated command replacing an idle agent.
                restoredAgentLifecycle.setResumeState(.observedAgentCommandRunning, panelId: panelId)
                break
            }
            restoredAgentLifecycle.setSnapshot(nil, panelId: panelId)
            restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
            retireAgentHookResumeBinding(panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            // A TUI prompt mark (OSC 133;A) is not the shell prompt returning
            // while the agent process is still alive.
            guard !restoredAgentHasLiveProcess(panelId: panelId, restoredAgent: restoredAgent) else { break }
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
            internallySeededInput: internallySeededInput.map { AutomaticTerminalTitle($0.trimmingCharacters(in: .whitespacesAndNewlines))?.value ?? $0.trimmingCharacters(in: .whitespacesAndNewlines) },
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
        if detached.customTitle != nil {
            panelCustomTitleSourcesByPanelId[detached.panelId] =
                detached.customTitleSource ?? .user
        } else {
            panelCustomTitleSourcesByPanelId.removeValue(
                forKey: detached.panelId
            )
        }
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
            resumeWorkingDirectory: detached.restoredResumeSessionWorkingDirectory,
            startupInput: detached.restoredStartupInput
        )
        managedAgentResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        if let resumeBinding = detached.resumeBinding {
            if surfaceResumeBindingMutationAllowed(resumeBinding, panelId: detached.panelId) {
                surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
            }
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
        if focus {
            focusPanelFromDockInteraction(
                panelId,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
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
                if surfaceResumeBindingMutationAllowed(binding, panelId: panelId) {
                    surfaceResumeBindingsByPanelId[panelId] = binding
                }
            }
        } else {
            if surfaceResumeBindingMutationAllowed(binding, panelId: panelId) {
                surfaceResumeBindingsByPanelId[panelId] = binding
            }
        }
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

    func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregate(
            statusKeyedStates: agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:],
            fallback: fallback
        )
    }

    func agentLifecycleStateForTextBoxEscape(panelId: UUID) -> AgentHibernationLifecycleState {
        AgentHibernationLifecycleState.aggregateForTextBoxEscape(
            statusKeyedStates: agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:]
        )
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
        let previousCodexLifecycle = agentRuntimeByPanelId[panelId]?
            .agentLifecycleStates["codex"]
        let stableTitle = stableDockTerminalTabTitle(panelId: panelId)?.title
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
        if previousCodexLifecycle != runtime.agentLifecycleStates["codex"] {
            _ = reconcileCodexTabTitlePresentation(
                panelId: panelId,
                fallback: stableTitle
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
    func removeDeferredAgentResumeRestore(panelId: UUID) {
        deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
        clearDeferredAgentResumeRestoreTransfer(panelId: panelId)
        if let claim = deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId) {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: claim.kind,
                sessionId: claim.sessionId
            )
        }
    }

    func clearDeferredAgentResumeRestoreTransfer(panelId: UUID) {
        if var transfer = detachedSurfaceTransfersByPanelId[panelId],
           transfer.deferredAgentResumeRestore != nil {
            transfer.deferredAgentResumeRestore = nil
            setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
        }
    }

    func cancelDeferredAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore,
        startRuntime: Bool = true
    ) {
        if startRuntime {
            (panels[panelId] as? TerminalPanel)?.restoreRecovery.state = nil
            (panels[panelId] as? TerminalPanel)?.surface.cancelStartupRestoreAdmission()
        } else {
            terminalStartupRestoreCoordinator.discardPendingRestoreForPanelTeardown(panelID: panelId)
            restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        }
        removeDeferredAgentResumeRestore(panelId: panelId)
        restoredAgentLifecycle.clearStartupInput(panelId: panelId)
        if startRuntime, restore.restorableAgent == nil {
            if let binding = restore.resumeBinding {
                retireAgentHookResumeBinding(panelId: panelId, matching: binding)
            }
        }
        if startRuntime {
            restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)
        }
    }

    func deferredAgentResumeRestoreMatchesCurrentSession(
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

    /// An unavailable scan retains the restore; it is never translated into shell input.
    func presentPendingAgentResumeRestores() {
        for panelID in deferredAgentResumeRestoresByPanelId.keys {
            (panels[panelID] as? TerminalPanel)?.restoreRecovery.state = .checking
        }
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
        for panelId in Array(detachedSurfaceTransfersByPanelId.keys) {
            clearDeferredAgentResumeRestoreTransfer(panelId: panelId)
        }
    }
}
