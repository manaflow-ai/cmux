import Foundation

extension DockSplitStore {
    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard panels[panelId] is TerminalPanel else {
            return false
        }
        let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false)
        guard startupInput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                binding.permitsTransportOnlyPersistentSSHRestore else {
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
        surfaceResumeBindingsByPanelId[panelId] = binding
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
                : surfaceResumeBindingsByPanelId[panelId])
        guard let binding else {
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
