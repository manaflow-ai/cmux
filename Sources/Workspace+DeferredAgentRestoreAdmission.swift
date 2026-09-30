import CmuxFoundation
import CmuxWorkspaces
import Foundation

extension Workspace {
    func resolveDeferredAgentResumeRestores(
        using index: RestorableAgentSessionIndex
    ) {
        let policy = Self.makeSessionRestorePolicyService()
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
            let expectedKind = restore.restorableAgent?.kind.rawValue ?? restore.resumeBinding?.kind
            guard index.isComplete(
                forPanelId: restore.stablePanelID,
                kind: expectedKind
            ) else {
                terminal.restoreRecovery.state = .checking
                continue
            }
            guard deferredAgentResumeRestoreMatchesCurrentSession(
                panelId: panelId,
                restore: restore
            ) else {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            let currentResumeBinding: SurfaceResumeBindingSnapshot?
            if let capturedBinding = restore.resumeBinding {
                guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
                      currentBinding.isAgentHookBinding,
                      currentBinding.isSameManagedSession(as: capturedBinding) else {
                    cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                    continue
                }
                // The staged snapshot owns this launch. A late SessionEnd from
                // the previous cmux can retire the live binding in place while
                // leaving the same session identity; do not turn that race into
                // a silent shell or rebuild the launch from autoResume=false.
                currentResumeBinding = capturedBinding
            } else {
                currentResumeBinding = nil
            }
            let expectedSessionId = restore.restorableAgent?.sessionId ?? restore.resumeBinding?.checkpointId
            let liveSessionOwner: LiveAgentSessionOwner? = if let expectedKind,
                let expectedSessionId {
                index.liveSessionOwner(
                    kind: expectedKind,
                    sessionID: expectedSessionId,
                    revalidateProcessEvidence: true
                )
            } else {
                nil
            }
            if let liveSessionOwner {
                terminal.restoreRecovery.state = .liveOwner(
                    kind: liveSessionOwner.kind, processID: liveSessionOwner.processID
                )
                continue
            }
            terminal.restoreRecovery.state = nil

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
            } else if let binding = currentResumeBinding ?? restore.resumeBinding {
                if restore.restoresRemoteWorkspaceTerminalSnapshot {
                    guard binding.launchFlavor.remoteContext == restore.remoteResumeContext else {
                        cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                        continue
                    }
                }
                let approvedBinding = policy.approvedSurfaceResumeBinding(
                    binding,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(
                        defaults: agentSessionAutoResumeDefaults
                    ),
                    promptForApproval: true,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                startupInput = approvedBinding.flatMap {
                    if restore.restoresRemoteWorkspaceTerminalSnapshot {
                        return $0.remoteStartupInput()
                    }
                    return policy.surfaceResumeStartupLaunch(forApprovedBinding: $0)?.initialInput
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
            let ownedClaim = restore.restoresRemoteWorkspaceTerminalSnapshot
                ? claim
                : nil
            if let ownedClaim,
               !AgentResumeLaunchGuard.shared.claimResumeLaunch(
                   kind: ownedClaim.kind,
                   sessionId: ownedClaim.sessionId
               ) {
                cancelDeferredAgentResumeRestore(panelId: panelId, restore: restore)
                continue
            }
            if let ownedClaim {
                deferredAgentResumeClaimsByPanelId[panelId] = ownedClaim
            }
            if let restoreWorkingDirectory = restore.resumeWorkingDirectory {
                restoredResumeSessionWorkingDirectoriesByPanelId[panelId] = restoreWorkingDirectory
            }
            restoredAgentLifecycle.setResumeState(
                .awaitingAutoResumeCommand,
                panelId: panelId
            )
            restoredAgentLifecycle.registerStartupInput(startupInput, panelId: panelId)
            let admitted = terminal.surface.admitStartupRestoreRuntime(
                initialInput: startupInput
            )
            if !admitted {
                restoredAgentLifecycle.clearStartupInput(panelId: panelId)
                if let ownedClaim {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                        kind: ownedClaim.kind,
                        sessionId: ownedClaim.sessionId
                    )
                }
                deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                restoredAgentLifecycle.setResumeState(
                    restore.restorableAgent == nil ? nil : .manualResumeAvailable,
                    panelId: panelId
                )
            } else {
                terminalStartupRestoreCoordinator.recordDeferredResumeIntent(
                    panelID: panelId,
                    snapshot: restore.restorableAgent,
                    resumeBinding: currentResumeBinding ?? restore.resumeBinding,
                    workingDirectory: restore.resumeWorkingDirectory ?? restore.workingDirectory
                )
                deferredAgentResumeRestoresByPanelId.removeValue(forKey: panelId)
                if let ownedClaim,
                   let pendingClaim = deferredAgentResumeClaimsByPanelId[panelId],
                   pendingClaim.kind == ownedClaim.kind,
                   pendingClaim.sessionId == ownedClaim.sessionId {
                    // After admission the guard's bounded TTL owns this claim;
                    // do not let later panel teardown release a newer claimant.
                    deferredAgentResumeClaimsByPanelId.removeValue(forKey: panelId)
                }
            }
        }
    }

}
