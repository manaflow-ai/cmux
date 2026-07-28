import CmuxCore
import Foundation

enum WorkspaceRemoteTerminalSessionPhase: Equatable {
    case launching
    case connected
}

@MainActor
extension Workspace {
    var hasAuthoritativelyConnectedRemoteTerminal: Bool {
        activeRemoteTerminalSurfaceIds.contains {
            remoteTerminalSessionPhasesBySurfaceId[$0] == .connected
        }
    }

    func markRemoteTerminalSessionLaunching(surfaceId: UUID) {
        guard activeRemoteTerminalSurfaceIds.contains(surfaceId) else { return }
        remoteTerminalSessionPhasesBySurfaceId[surfaceId] = .launching
    }

    @discardableResult
    func markRemoteTerminalSessionConnected(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let configuration = remoteConfiguration,
              activeRemoteTerminalSurfaceIds.contains(surfaceId),
              relayPort.map({ $0 == configuration.relayPort }) ?? true else {
            return false
        }

        remoteTerminalSessionPhasesBySurfaceId[surfaceId] = .connected
        remoteConnectionState = .connected
        remoteConnectionDetail = nil
        clearProxyOnlyRemoteSidebarArtifacts()
        applyBrowserRemoteWorkspaceStatusToPanels()
        postRemoteConnectionPresentationDidChange()
        return true
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
    }
}
