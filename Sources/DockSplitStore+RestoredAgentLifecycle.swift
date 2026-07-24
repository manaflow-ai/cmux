import CmuxWorkspaces
import Foundation

extension DockSplitStore {
    func clearSessionRestoreState(panelId: UUID) {
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
        restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard let terminal = panels[panelId] as? TerminalPanel else { return }
        terminal.updateShellActivityState(state)
        let restoredAgent = restoredAgentLifecycle.snapshotsByPanelId[panelId]

        switch (state, restoredAgentLifecycle.resumeStatesByPanelId[panelId]) {
        case (.commandRunning, .some(.awaitingAutoResumeCommand)):
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = .autoResumeCommandRunning
        case (.commandRunning, .some(.manualResumeAvailable)):
            restoredAgentLifecycle.snapshotsByPanelId.removeValue(forKey: panelId)
            restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
            clearAgentHookResumeBinding(panelId: panelId)
        case (.promptIdle, .some(.autoResumeCommandRunning)),
             (.promptIdle, .some(.observedAgentCommandRunning)):
            if restoredAgent != nil {
                let runtimeIdentities = Set(
                    detachedSurfaceTransfersByPanelId[panelId]?.agentRuntime?
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
            } else {
                restoredAgentLifecycle.resumeStatesByPanelId.removeValue(forKey: panelId)
            }
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            clearAgentHookResumeBinding(panelId: panelId)
        default:
            break
        }
    }

    func adoptSessionRestoreState(from detached: Workspace.DetachedSurfaceTransfer) {
        restoredAgentLifecycle.seedTransferredState(
            panelId: detached.panelId,
            snapshot: detached.restorableAgent,
            resumeState: detached.restorableAgentResumeState,
            completedGeneration: detached.restoredAgentCompletedGeneration
        )
        if let resumeBinding = detached.resumeBinding {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        }
        if let directory = detached.restoredResumeSessionWorkingDirectory {
            restoredResumeSessionWorkingDirectoriesByPanelId[detached.panelId] = directory
        }
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
            restoredAgentLifecycle.resumeStatesByPanelId[panelId] = preparation.queuedStartupInput
                ? .awaitingAutoResumeCommand
                : .manualResumeAvailable
            restoredAgentLifecycle.invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        AgentHibernationController.shared.recordTerminalFocus(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if focus { focusPanel(panelId) }
        return true
    }

    private func clearAgentHookResumeBinding(panelId: UUID) {
        if surfaceResumeBindingsByPanelId[panelId]?.isAgentHookBinding == true {
            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
    }
}
