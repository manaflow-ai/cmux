import CmuxCore
import Foundation

enum WorkspaceRemoteTerminalSessionPhase: Equatable {
    case launching
    case connected
    case ended
}

enum WorkspaceRemoteTerminalAuthority: Equatable, Sendable {
    case relayPort(Int)
    case persistentTransport(String)

    init?(configuration: WorkspaceRemoteConfiguration) {
        if configuration.preserveAfterTerminalExit {
            self = .persistentTransport(configuration.proxyBrokerTransportKey)
        } else if let relayPort = configuration.relayPort, relayPort > 0 {
            self = .relayPort(relayPort)
        } else {
            return nil
        }
    }

    func matches(_ configuration: WorkspaceRemoteConfiguration) -> Bool {
        self == Self(configuration: configuration)
    }
}

struct WorkspaceRemoteTerminalSessionState: Equatable {
    let phase: WorkspaceRemoteTerminalSessionPhase
    let authority: WorkspaceRemoteTerminalAuthority
}

struct PendingWorkspaceRemoteTerminalConnection: Equatable {
    let authority: WorkspaceRemoteTerminalAuthority
}

@MainActor
extension Workspace {
    var hasAuthoritativelyConnectedRemoteTerminal: Bool {
        hasAuthoritativelyConnectedRemoteTerminal(in: [])
    }

    func hasAuthoritativelyConnectedRemoteTerminal(
        in externalDocks: [DockSplitStore]
    ) -> Bool {
        guard let configuration = remoteConfiguration else { return false }
        let hasConnectedWorkspaceSurface = activeRemoteTerminalSurfaceIds.contains {
            guard let state = remoteTerminalSessionStatesBySurfaceId[$0] else { return false }
            return state.phase == .connected && state.authority.matches(configuration)
        }
        let workspaceDockIsConnected = _dockSplit?.hasAuthoritativelyConnectedRemoteTerminal(
            presentationWorkspaceID: id,
            configuration: configuration
        ) == true
        let externalDockIsConnected = externalDocks.contains {
            $0.hasAuthoritativelyConnectedRemoteTerminal(
                presentationWorkspaceID: id,
                configuration: configuration
            )
        }
        return hasConnectedWorkspaceSurface || workspaceDockIsConnected || externalDockIsConnected
    }

    func markRemoteTerminalSessionLaunching(surfaceId: UUID) {
        guard activeRemoteTerminalSurfaceIds.contains(surfaceId),
              let configuration = remoteConfiguration,
              let authority = WorkspaceRemoteTerminalAuthority(configuration: configuration) else {
            remoteTerminalSessionStatesBySurfaceId.removeValue(forKey: surfaceId)
            return
        }
        remoteTerminalSessionStatesBySurfaceId[surfaceId] = WorkspaceRemoteTerminalSessionState(
            phase: .launching,
            authority: authority
        )
    }

    @discardableResult
    func markRemoteTerminalSessionConnected(
        surfaceId: UUID,
        relayPort: Int?,
        allowUntracked: Bool = false
    ) -> Bool {
        guard let relayPort, relayPort > 0 else { return false }
        return markRemoteTerminalSessionConnected(
            surfaceId: surfaceId,
            authority: .relayPort(relayPort),
            allowUntracked: allowUntracked
        )
    }

    @discardableResult
    func markRemoteTerminalSessionConnected(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        allowUntracked: Bool = false
    ) -> Bool {
        guard let configuration = remoteConfiguration else {
            guard panels[surfaceId] is TerminalPanel else { return false }
            pendingRemoteTerminalConnectionsBySurfaceId[surfaceId] =
                PendingWorkspaceRemoteTerminalConnection(authority: authority)
            return true
        }
        let isTracked = activeRemoteTerminalSurfaceIds.contains(surfaceId)
        guard isTracked || allowUntracked,
              authority.matches(configuration) else {
            return false
        }

        if isTracked {
            remoteTerminalSessionStatesBySurfaceId[surfaceId] =
                WorkspaceRemoteTerminalSessionState(phase: .connected, authority: authority)
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
                authority: connection.authority
            )
        }
    }

    func clearRemoteTerminalSessionPhase(surfaceId: UUID) {
        remoteTerminalSessionStatesBySurfaceId.removeValue(forKey: surfaceId)
    }

    func restoreRemoteTerminalSessionPhase(
        _ phase: WorkspaceRemoteTerminalSessionPhase?,
        authority: WorkspaceRemoteTerminalAuthority?,
        surfaceId: UUID
    ) {
        guard let phase,
              let authority,
              let configuration = remoteConfiguration,
              authority.matches(configuration),
              activeRemoteTerminalSurfaceIds.contains(surfaceId) else {
            return
        }
        remoteTerminalSessionStatesBySurfaceId[surfaceId] =
            WorkspaceRemoteTerminalSessionState(phase: phase, authority: authority)
        if phase == .connected {
            applyRemoteTerminalConnectedPresentation()
        }
    }
}
