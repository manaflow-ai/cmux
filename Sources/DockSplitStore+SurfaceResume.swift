import Foundation

extension DockSplitStore {
    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard panels[panelId] is TerminalPanel,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              restoredAgentLifecycle.canActivateAgentRuntimeBinding(
                  binding,
                  panelId: panelId
              ) else {
            return false
        }
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
           let previous = restoredAgentLifecycle.recordAgentRuntimeReplacementIfNeeded(
               currentBinding: managedAgentResumeBinding(panelId: panelId),
               replacement: binding,
               panelId: panelId
           ) {
            clearAgentRestoreStateOwned(
                by: previous,
                panelId: panelId,
                preserveCompletedTombstone: false
            )
            clearAgentRuntimeOwned(by: previous, panelId: panelId)
        }
        if binding.hasCompleteManagedSessionIdentity {
            managedAgentResumeBindingsByPanelId[panelId] = binding
        } else if binding.isAgentHookBinding {
            managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        restoredAgentLifecycle.activateAgentRuntimeBinding(binding, panelId: panelId)
        return true
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
        restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
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
                    ?? restoredAgentLifecycle.eligibleRetiredAgentRuntimeBinding(
                        panelId: panelId
                    )
                : surfaceResumeBindingsByPanelId[panelId])
        guard let binding else {
            return false
        }

        let clearsManagedBinding = managedBinding.map {
            $0 == binding || $0.acceptsAgentRuntimeCleanup(from: binding)
        } == true
        if clearsManagedBinding {
            restoredAgentLifecycle.recordAgentRuntimeRetirement(
                binding,
                panelId: panelId,
                agentSessionEnded: agentSessionEnded
            )
            managedAgentResumeBindingsByPanelId.removeValue(forKey: panelId)
            if let effectiveBinding = surfaceResumeBindingsByPanelId[panelId],
               effectiveBinding == binding
                || effectiveBinding.acceptsAgentRuntimeCleanup(from: binding) {
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
            return true
        }

        if agentSessionEnded,
           restoredAgentLifecycle.endRetiredAgentRuntimeBinding(
               binding,
               panelId: panelId
           ) {
            return true
        }

        guard let effectiveBinding = surfaceResumeBindingsByPanelId[panelId],
              effectiveBinding == binding else {
            return false
        }
        restoredAgentLifecycle.recordAgentRuntimeRetirement(
            binding,
            panelId: panelId,
            agentSessionEnded: agentSessionEnded
        )
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        clearAgentRestoreStateOwned(
            by: binding,
            panelId: panelId,
            preserveCompletedTombstone: true,
            agentSessionEnded: agentSessionEnded
        )
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

    func persistentSSHResumeContext(panelId: UUID) -> SurfaceResumeRemoteContext? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              let sessionID = transfer.remotePTYSessionID?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        return SurfaceResumeRemoteContext(
            workspaceID: transfer.sessionRestoreWorkspaceId,
            surfaceID: panelId,
            persistentPTYSessionID: sessionID
        )
    }

    /// Returns the persistent-SSH owner only while the detached terminal's
    /// current attach is authoritatively connected to its persistent transport.
    func authoritativelyConnectedPersistentSSHResumeContext(
        panelId: UUID
    ) -> SurfaceResumeRemoteContext? {
        guard let context = persistentSSHResumeContext(panelId: panelId),
              let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.remoteTerminalSessionPhase == .connected,
              let authority = transfer.remoteTerminalAuthority,
              authority.preservesRemotePTYAcrossAttachAttempts,
              transfer.remoteCleanupConfiguration.map(authority.matches) ?? true else {
            return nil
        }
        return context
    }

    func persistentSSHResumeRegistration(
        panelId: UUID
    ) -> (context: SurfaceResumeRemoteContext, relayToken: String)? {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              let context = persistentSSHResumeContext(panelId: panelId) else {
            return nil
        }
        let sourceWorkspaceId = context.workspaceID
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
            context,
            relayToken
        )
    }
}
