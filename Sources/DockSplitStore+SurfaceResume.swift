import Foundation

extension DockSplitStore {
    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard panels[panelId] is TerminalPanel,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let activeRestoreClaim = surfaceResumeRestoreClaim(for: panelId)
        if let activeRestoreClaim {
            guard activeRestoreClaim.binding.acceptsRestoreBindingClaim(from: binding) else {
                return false
            }
        }
        // Keep the provenance comparison in the same MainActor mutation as the
        // assignment; the managed hook binding remains authoritative while a
        // process-detected binding is temporarily effective in the Dock.
        // Mirrors managedAgentResumeBinding(panelId:) without its sync-on-read:
        // a rejected incoming binding must not promote the effective binding to
        // managed state as a side effect of this acceptance check.
        let effectivePreviousBinding = surfaceResumeBindingsByPanelId[panelId]
        let existingBinding: SurfaceResumeBindingSnapshot?
        if let effectivePreviousBinding, effectivePreviousBinding.hasCompleteManagedSessionIdentity {
            existingBinding = effectivePreviousBinding
        } else {
            existingBinding = managedAgentResumeBindingsByPanelId[panelId] ?? effectivePreviousBinding
        }
        guard binding.allowsCodexAgentHookReplacement(
            of: existingBinding
        ) else {
            return false
        }
        if activeRestoreClaim != nil {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        }
        let previousRestorableAgent = restoredAgentLifecycle.snapshotsByPanelId[panelId]
        let cachedManagedBinding =
            detachedSurfaceTransfersByPanelId[panelId]?.resolvedManagedAgentResumeBinding
        if binding.isAgentHookBinding,
           let cachedTransfer = detachedSurfaceTransfersByPanelId[panelId] {
            let cachedSessionMetadataExists =
                cachedManagedBinding != nil ||
                cachedTransfer.restorableAgent != nil ||
                cachedTransfer.restorableAgentResumeState != nil ||
                cachedTransfer.restoredAgentCompletedGeneration != nil ||
                cachedTransfer.restoredResumeSessionWorkingDirectory != nil
            let incomingBindingMatchesCachedSession: Bool
            if let cachedManagedBinding {
                incomingBindingMatchesCachedSession =
                    cachedManagedBinding.isSameManagedSession(as: binding)
            } else if let cachedAgent = cachedTransfer.restorableAgent {
                incomingBindingMatchesCachedSession =
                    binding.hasCompleteManagedSessionIdentity &&
                    Workspace.restorableAgentForSessionRestore(
                        cachedAgent,
                        resumeBinding: binding
                    ) != nil
            } else {
                incomingBindingMatchesCachedSession = false
            }
            if cachedSessionMetadataExists {
                if incomingBindingMatchesCachedSession {
                    invalidatedCachedTransferAgentSessionPanelIds.remove(panelId)
                    replacedCachedTransferAgentSessionPanelIds.remove(panelId)
                } else {
                    invalidatedCachedTransferAgentSessionPanelIds.insert(panelId)
                    replacedCachedTransferAgentSessionPanelIds.insert(panelId)
                    clearAgentRestoreStateIncompatible(
                        with: binding,
                        panelId: panelId
                    )
                }
            }
        }
        if binding.isAgentHookBinding,
           let previous = managedAgentResumeBinding(panelId: panelId),
           !previous.isSameManagedSession(as: binding) {
            clearAgentRestoreStateOwned(
                by: previous,
                panelId: panelId,
                preserveCompletedTombstone: false
            )
        }
        if binding.hasCompleteManagedSessionIdentity {
            managedAgentResumeBindingsByPanelId[panelId] = binding
        } else if binding.isAgentHookBinding {
            managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        // This transient cwd belongs to the binding restored at launch. Let a
        // same-session hook refresh keep its cwd rescue, but never let it
        // override a replacement session's structured restore record.
        if let previous = effectivePreviousBinding,
           previous.kind != binding.kind
            || previous.checkpointId != binding.checkpointId
            || previous.cwd != binding.cwd
            || previous.launchCommand?.workingDirectory != binding.launchCommand?.workingDirectory
            || (previous.launchCommand == nil && binding.launchCommand == nil
                && previous.command != binding.command) {
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        }
        if let restorableAgent = binding.managedRestorableAgentSnapshot(
            replacing: previousRestorableAgent
        ) {
            restoredAgentLifecycle.setSnapshot(restorableAgent, panelId: panelId)
            restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        if restoredAgentLifecycle.recoveryNeededWorkingDirectoriesByPanelId[panelId] != nil,
           OneShotTerminalLauncherStore.enterableWorkingDirectory(binding.cwd) != nil {
            restoredAgentLifecycle.clearRecoveryNeeded(panelId: panelId)
            var recoveryTransfer = detachedSurfaceTransfersByPanelId[panelId]
            recoveryTransfer?.recoveryNeededWorkingDirectory = nil
            if let recoveryTransfer {
                setDetachedSurfaceTransfer(recoveryTransfer, forPanelID: panelId)
            }
            if let tabId = surfaceId(forPanelId: panelId),
               let panel = panels[panelId] {
                let customTitle = recoveryTransfer?.customTitle?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let baseTitle = customTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? recoveryTransfer?.cachedTitle
                    ?? panel.displayTitle
                bonsplitController.updateTab(
                    tabId,
                    title: baseTitle,
                    hasCustomTitle: customTitle != nil
                )
            }
        }
        return true
    }

    /// Atomically claims the current binding generation for a CLI restore.
    ///
    /// The claim is consumed by the next same-session hook refresh and blocks a
    /// different checkpoint from replacing the binding during the handoff.
    @discardableResult
    func claimSurfaceResumeBinding(
        panelId: UUID,
        expectedCheckpointID: String,
        expectedSource: String,
        expectedUpdatedAt: TimeInterval
    ) -> Bool {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.isAgentHookBinding,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
                  == expectedCheckpointID.trimmingCharacters(in: .whitespacesAndNewlines),
              binding.source?.trimmingCharacters(in: .whitespacesAndNewlines)
                  == expectedSource.trimmingCharacters(in: .whitespacesAndNewlines),
              expectedUpdatedAt.isFinite,
              binding.updatedAt == expectedUpdatedAt else {
            return false
        }
        surfaceResumeRestoreClaimsByPanelId[panelId] = (
            binding: binding,
            claimedAt: Date.now
        )
        return true
    }

    /// Checks a non-socket binding writer against an in-flight restore claim.
    ///
    /// Snapshot and transfer paths historically wrote the effective binding
    /// directly. They must share the same claim gate as hook publications so a
    /// different process observation cannot replace the generation authorized
    /// for execution.
    @discardableResult
    func surfaceResumeBindingMutationAllowed(
        _ incoming: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard let claim = surfaceResumeRestoreClaim(for: panelId) else {
            return true
        }
        guard claim.binding.acceptsRestoreBindingClaim(from: incoming) else {
            return false
        }
        surfaceResumeRestoreClaimsByPanelId[panelId] = (
            binding: incoming,
            claimedAt: claim.claimedAt
        )
        return true
    }

    /// Returns false while a claimed generation is still active.
    @discardableResult
    func surfaceResumeBindingRemovalAllowed(panelId: UUID) -> Bool {
        surfaceResumeRestoreClaim(for: panelId) == nil
    }

    private func surfaceResumeRestoreClaim(
        for panelId: UUID
    ) -> (binding: SurfaceResumeBindingSnapshot, claimedAt: Date)? {
        guard let claim = surfaceResumeRestoreClaimsByPanelId[panelId] else {
            return nil
        }
        guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
              currentBinding.checkpointId == claim.binding.checkpointId,
              currentBinding.source == claim.binding.source,
              currentBinding.updatedAt == claim.binding.updatedAt else {
            // A direct lifecycle mutation replaced the claimed generation
            // without going through the hook setter. Do not let that old claim
            // block a later, legitimate binding.
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        guard Date.now.timeIntervalSince(claim.claimedAt) < SurfaceResumeBindingSnapshot.restoreClaimTTL else {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        return claim
    }

    private func clearAgentRestoreStateIncompatible(
        with binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        if let snapshot = restoredAgentLifecycle.snapshotsByPanelId[panelId],
           Workspace.restorableAgentForSessionRestore(
               snapshot,
               resumeBinding: binding
           ) != nil {
            return
        }
        clearRestoredAgentContinuationState(panelId: panelId)
    }

    private func clearRestoredAgentContinuationState(panelId: UUID) {
        restoredAgentLifecycle.clearSessionRestore(panelId: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    @discardableResult
    func clearSurfaceResumeBinding(
        panelId: UUID,
        binding requestedBinding: SurfaceResumeBindingSnapshot? = nil,
        agentSessionEnded: Bool = false
    ) -> Bool {
        let managedBinding = managedAgentResumeBinding(panelId: panelId)
        let binding = requestedBinding
            ?? (agentSessionEnded
                ? managedBinding
                : surfaceResumeBindingsByPanelId[panelId])
        guard let binding else {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return false
        }

        let clearsManagedBinding = managedBinding.map {
            Self.dockResumeBindingsRepresentSameManagedSession($0, binding)
        } == true
        if clearsManagedBinding {
            managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
            if let effectiveBinding = surfaceResumeBindingsByPanelId[panelId],
               Self.dockResumeBindingsRepresentSameManagedSession(effectiveBinding, binding) {
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            }
            if cachedTransferContainsManagedSession(
                panelId: panelId,
                matching: binding
            ) {
                invalidatedCachedTransferAgentSessionPanelIds.insert(panelId)
            }
            clearAgentRestoreStateOwned(
                by: binding,
                panelId: panelId,
                preserveCompletedTombstone: true,
                agentSessionEnded: agentSessionEnded
            )
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return true
        }

        guard let effectiveBinding = surfaceResumeBindingsByPanelId[panelId],
              effectiveBinding == binding else {
            return false
        }
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        clearAgentRestoreStateOwned(
            by: binding,
            panelId: panelId,
            preserveCompletedTombstone: true,
            agentSessionEnded: agentSessionEnded
        )
        surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        return true
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
    }

    func managedAgentResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        let managedBinding = managedAgentResumeBindingsByPanelId[panelId]
        guard let effectiveBinding = surfaceResumeBindingsByPanelId[panelId],
              effectiveBinding.hasCompleteManagedSessionIdentity else {
            return managedBinding
        }
        if managedBinding != effectiveBinding {
            managedAgentResumeBindingsByPanelId[panelId] = effectiveBinding
        }
        return effectiveBinding
    }

    private static func dockResumeBindingsRepresentSameManagedSession(
        _ lhs: SurfaceResumeBindingSnapshot,
        _ rhs: SurfaceResumeBindingSnapshot
    ) -> Bool {
        lhs == rhs ||
            (lhs.isAgentHookBinding &&
                rhs.isAgentHookBinding &&
                lhs.isSameManagedSession(as: rhs))
    }

    private func cachedTransferContainsManagedSession(
        panelId: UUID,
        matching binding: SurfaceResumeBindingSnapshot
    ) -> Bool {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId] else {
            return false
        }
        if let cachedBinding = transfer.resolvedManagedAgentResumeBinding,
           (!cachedBinding.hasCompleteManagedSessionIdentity ||
               !binding.hasCompleteManagedSessionIdentity ||
               cachedBinding.isSameManagedSession(as: binding)) {
            return true
        }
        guard let cachedAgent = transfer.restorableAgent else {
            return false
        }
        return Workspace.restorableAgentForSessionRestore(
            cachedAgent,
            resumeBinding: binding
        ) != nil
    }

    private func clearAgentRestoreStateOwned(
        by binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        preserveCompletedTombstone: Bool,
        agentSessionEnded: Bool = false
    ) {
        guard binding.isAgentHookBinding else { return }
        if let snapshot = restoredAgentLifecycle.snapshotsByPanelId[panelId],
           Workspace.restorableAgentForSessionRestore(
               snapshot,
               resumeBinding: binding
           ) == nil {
            return
        }
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        if agentSessionEnded {
            markRestoredAgentCompleted(panelId: panelId)
            return
        }
        if preserveCompletedTombstone,
           restoredAgentLifecycle.resumeStatesByPanelId[panelId] == .completedAgentExit {
            return
        }
        clearRestoredAgentContinuationState(panelId: panelId)
    }

    func persistentSSHResumeRegistration(
        panelId: UUID
    ) -> (context: SurfaceResumeRemoteContext, relayToken: String)? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              let sessionID = transfer.remotePTYSessionID?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        let sourceWorkspaceId = transfer.sessionRestoreWorkspaceId
        let sourceWorkspace = AppDelegate.shared?.workspaceFor(tabId: sourceWorkspaceId)
        guard let configuration = transfer.remoteCleanupConfiguration ?? sourceWorkspace?.remoteConfiguration,
              configuration.transport == .ssh,
              configuration.preserveAfterTerminalExit,
              !configuration.skipDaemonBootstrap,
              configuration.persistentDaemonSlot != nil,
              let relayToken = configuration.relayToken else {
            return nil
        }
        return (
            SurfaceResumeRemoteContext(
                workspaceID: sourceWorkspaceId,
                surfaceID: panelId,
                persistentPTYSessionID: sessionID
            ),
            relayToken
        )
    }
}
