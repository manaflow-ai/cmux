import CmuxCore
import Foundation

enum WorkspaceRemoteTerminalSessionPhase: Equatable {
    case launching
    case connected
    case ended
}

struct PendingWorkspaceRemoteTerminalConnection: Equatable {
    let relayPort: Int?
}

@MainActor
extension Workspace {
    var hasAuthoritativelyConnectedRemoteTerminal: Bool {
        activeRemoteTerminalSurfaceIds.contains {
            remoteTerminalSessionPhasesBySurfaceId[$0] == .connected
        } || _dockSplit?.hasAuthoritativelyConnectedRemoteTerminal == true
    }

    func markRemoteTerminalSessionLaunching(surfaceId: UUID) {
        guard activeRemoteTerminalSurfaceIds.contains(surfaceId) else { return }
        remoteTerminalSessionPhasesBySurfaceId[surfaceId] = .launching
    }

    @discardableResult
    func markRemoteTerminalSessionConnected(
        surfaceId: UUID,
        relayPort: Int?,
        allowUntracked: Bool = false
    ) -> Bool {
        guard let configuration = remoteConfiguration else {
            guard panels[surfaceId] is TerminalPanel else { return false }
            pendingRemoteTerminalConnectionsBySurfaceId[surfaceId] =
                PendingWorkspaceRemoteTerminalConnection(relayPort: relayPort)
            return true
        }
        let isTracked = activeRemoteTerminalSurfaceIds.contains(surfaceId)
        guard isTracked || allowUntracked,
              relayPort.map({ $0 == configuration.relayPort }) ?? true else {
            return false
        }

        if isTracked {
            remoteTerminalSessionPhasesBySurfaceId[surfaceId] = .connected
        }
        applyRemoteTerminalConnectedPresentation()
        return true
    }

    private func applyRemoteTerminalConnectedPresentation() {
        remoteConnectionState = .connected
        remoteConnectionDetail = nil
        clearProxyOnlyRemoteSidebarArtifacts()
        applyBrowserRemoteWorkspaceStatusToPanels()
        postRemoteConnectionPresentationDidChange()
    }

    func applyPendingRemoteTerminalConnections() {
        let pendingConnections = pendingRemoteTerminalConnectionsBySurfaceId
        pendingRemoteTerminalConnectionsBySurfaceId.removeAll()
        for (surfaceId, connection) in pendingConnections {
            _ = markRemoteTerminalSessionConnected(
                surfaceId: surfaceId,
                relayPort: connection.relayPort
            )
        }
    }

    func clearRemoteTerminalSessionPhase(surfaceId: UUID) {
        remoteTerminalSessionPhasesBySurfaceId.removeValue(forKey: surfaceId)
    }

    func restoreRemoteTerminalSessionPhase(
        _ phase: WorkspaceRemoteTerminalSessionPhase?,
        surfaceId: UUID
    ) {
        guard let phase, activeRemoteTerminalSurfaceIds.contains(surfaceId) else { return }
        remoteTerminalSessionPhasesBySurfaceId[surfaceId] = phase
        if phase == .connected {
            applyRemoteTerminalConnectedPresentation()
        }
    }
}
