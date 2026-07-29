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
        authority: WorkspaceRemoteTerminalAuthority
    ) -> Bool {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal else {
            return false
        }
        transfer.remoteTerminalSessionPhase = .connected
        transfer.remoteTerminalAuthority = authority
        detachedSurfaceTransfersByPanelId[panelId] = transfer
        return true
    }

    func ownsRemoteTerminalTransfer(
        panelId: UUID,
        presentationWorkspaceID: UUID
    ) -> Bool {
        guard let transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal else {
            return false
        }
        return switch scope {
        case .workspace:
            workspaceId == presentationWorkspaceID
        case .global:
            transfer.sessionRestoreWorkspaceId == presentationWorkspaceID
        }
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
        authority: WorkspaceRemoteTerminalAuthority
    ) -> Bool {
        guard var transfer = detachedSurfaceTransfersByPanelId[panelId],
              transfer.isRemoteTerminal,
              transfer.remoteTerminalAuthority.map({ $0 == authority }) ?? true else {
            return false
        }
        transfer.remoteTerminalSessionPhase = .ended
        transfer.remoteTerminalAuthority = authority
        detachedSurfaceTransfersByPanelId[panelId] = transfer
        return true
    }

    func hasAuthoritativelyConnectedRemoteTerminal(
        presentationWorkspaceID: UUID,
        configuration: WorkspaceRemoteConfiguration
    ) -> Bool {
        detachedSurfaceTransfersByPanelId.values.contains { transfer in
            guard ownsRemoteTerminalTransfer(
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
}
