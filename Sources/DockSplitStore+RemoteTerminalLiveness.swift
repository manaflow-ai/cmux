import CmuxCore
import Foundation

extension DockSplitStore {
    func markRemoteTerminalSessionConnected(panelId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort, relayPort > 0 else { return false }
        return markRemoteTerminalSessionConnected(
            panelId: panelId,
            authority: .relayPort(relayPort)
        )
    }

    func markRemoteTerminalSessionConnected(
        panelId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID? = nil,
        attemptID: UUID? = nil
    ) -> Bool {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              transfer.remoteCleanupConfiguration.map(authority.matches) ?? true,
              matchesTerminalLifecycle(
                  panelId: panelId,
                  terminalLifecycleID: terminalLifecycleID
              ) else {
            return false
        }
        if transfer.remoteTerminalSessionPhase == .ended {
            guard let terminalLifecycleID,
                  let endedLifecycleID = transfer.remoteTerminalLifecycleID,
                  terminalLifecycleID != endedLifecycleID else {
                return false
            }
        }
        if let attemptID,
           transfer.remoteTerminalAttemptID != attemptID {
            return false
        }
        transfer.remoteTerminalSessionPhase = .connected
        transfer.remoteTerminalAuthority = authority
        transfer.remoteTerminalLifecycleID =
            terminalLifecycleID ?? transfer.remoteTerminalLifecycleID
        transfer.remoteTerminalAttemptID =
            attemptID ?? transfer.remoteTerminalAttemptID
        setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
        return true
    }

    func markRemoteTerminalSessionLaunching(
        panelId: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID
    ) -> Bool {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              matchesTerminalLifecycle(
                  panelId: panelId,
                  terminalLifecycleID: terminalLifecycleID
              ) else {
            return false
        }
        if transfer.remoteTerminalSessionPhase == .ended,
           transfer.remoteTerminalLifecycleID == terminalLifecycleID {
            return false
        }
        transfer.remoteTerminalSessionPhase = .launching
        transfer.remoteTerminalLifecycleID = terminalLifecycleID
        transfer.remoteTerminalAttemptID = attemptID
        setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
        return true
    }

    func markRemoteTerminalSessionConnected(
        panelId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        presentationWorkspaceID: UUID,
        terminalLifecycleID: UUID?,
        attemptID: UUID? = nil
    ) -> Bool {
        guard ownsRemoteTerminalTransfer(
                  panelId: panelId,
                  presentationWorkspaceID: presentationWorkspaceID
              ),
              let configuration = detachedSurfaceTransfersByPanelId[panelId]?
                  .remoteCleanupConfiguration,
              authority.matches(configuration) else {
            return false
        }
        return markRemoteTerminalSessionConnected(
            panelId: panelId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID
        )
    }

    func ownsRemoteTerminalTransfer(
        panelId: UUID,
        presentationWorkspaceID: UUID
    ) -> Bool {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal else {
            return false
        }
        // The callback carries the workspace captured when the terminal
        // launched. Container moves retarget `workspaceId`, but restore
        // identity remains bound to that terminal process.
        return transfer.sessionRestoreWorkspaceId == presentationWorkspaceID
    }

    func markRemoteTerminalSessionEnded(panelId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort, relayPort > 0 else { return false }
        return markRemoteTerminalSessionEnded(
            panelId: panelId,
            authority: .relayPort(relayPort)
        )
    }

    func markRemoteTerminalSessionEnded(
        panelId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID? = nil
    ) -> Bool {
        markRemoteTerminalSessionEnded(
            panelId: panelId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            afterValidation: { true }
        )
    }

    /// Commits the Dock end transition only after both authorities validate.
    func markRemoteTerminalSessionEnded(
        panelId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID? = nil,
        afterValidation workspaceTransition: () -> Bool
    ) -> Bool {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              transfer.remoteCleanupConfiguration.map(authority.matches) ?? true,
              transfer.remoteTerminalAuthority.map({ $0 == authority }) ?? true,
              matchesTerminalLifecycle(
                  panelId: panelId,
                  terminalLifecycleID: terminalLifecycleID
              ),
              workspaceTransition() else {
            return false
        }
        transfer.remoteTerminalSessionPhase = .ended
        transfer.remoteTerminalAuthority = authority
        transfer.remoteTerminalLifecycleID =
            terminalLifecycleID ?? transfer.remoteTerminalLifecycleID
        transfer.remoteTerminalAttemptID = nil
        setDetachedSurfaceTransfer(transfer, forPanelID: panelId)
        return true
    }

    func hasAuthoritativelyConnectedRemoteTerminal(
        presentationWorkspaceID: UUID,
        configuration: WorkspaceRemoteConfiguration,
        excludingPanelId: UUID? = nil
    ) -> Bool {
        detachedSurfaceTransfersByPanelId.values.contains { transfer in
            guard transfer.panelId != excludingPanelId,
                  ownsRemoteTerminalTransfer(
                      panelId: transfer.panelId,
                      presentationWorkspaceID: presentationWorkspaceID
                  ),
                  transfer.remoteTerminalSessionPhase == .connected,
                  let authority = transfer.remoteTerminalAuthority else {
                return false
            }
            return authority.matches(configuration)
        }
    }

    private func matchesTerminalLifecycle(
        panelId: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool {
        guard let terminalLifecycleID else { return true }
        guard let terminalPanel = panels[panelId] as? TerminalPanel else {
            return false
        }
        return terminalPanel.surface.terminalLifecycleId == terminalLifecycleID
    }
}
