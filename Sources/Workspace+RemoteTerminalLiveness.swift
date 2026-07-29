import CmuxControlSocket
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

struct PendingWorkspaceRemoteTerminalConnection {
    let authority: WorkspaceRemoteTerminalAuthority
    let terminalLifecycleID: UUID?
    let commitLease: (any ControlRemotePTYLifecycleCommitLease)?
}

private enum WorkspaceRemoteTerminalConnectionTarget {
    case pending
    case configured(isTracked: Bool)
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
        allowUntracked: Bool = false,
        terminalLifecycleID: UUID? = nil,
        commitLease: (any ControlRemotePTYLifecycleCommitLease)? = nil
    ) -> Bool {
        if let terminalLifecycleID {
            guard let terminalPanel = panels[surfaceId] as? TerminalPanel,
                  terminalPanel.surface.terminalLifecycleId == terminalLifecycleID else {
                return false
            }
        }
        guard let target = remoteTerminalConnectionTarget(
            surfaceId: surfaceId,
            authority: authority,
            allowUntracked: allowUntracked
        ) else {
            return false
        }
        return commitRemoteTerminalSessionConnected(
            target: target,
            surfaceId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            commitLease: commitLease
        )
    }

    func markDockRemoteTerminalSessionConnected(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID? = nil,
        commitLease: (any ControlRemotePTYLifecycleCommitLease)? = nil,
        dock: DockSplitStore
    ) -> Bool {
        guard dock.ownsRemoteTerminalTransfer(
                  panelId: surfaceId,
                  presentationWorkspaceID: id
              ),
              let target = remoteTerminalConnectionTarget(
                  surfaceId: surfaceId,
                  authority: authority,
                  allowUntracked: true
              ) else {
            return false
        }
        return commitRemoteTerminalSessionConnected(
            target: target,
            surfaceId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            commitLease: commitLease,
            beforeWorkspaceMutation: {
                dock.markRemoteTerminalSessionConnected(
                    panelId: surfaceId,
                    authority: authority,
                    terminalLifecycleID: terminalLifecycleID
                )
            }
        )
    }

    func markDockRemoteTerminalSessionEnded(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        relayPort: Int?,
        terminalLifecycleID: UUID?,
        dock: DockSplitStore
    ) -> Bool {
        guard dock.ownsRemoteTerminalTransfer(
                  panelId: surfaceId,
                  presentationWorkspaceID: id
              ),
              remoteConfiguration.map(authority.matches) ??
                (pendingRemoteTerminalConnectionsBySurfaceId[surfaceId]?.authority ==
                    authority) else {
            return false
        }
        return dock.markRemoteTerminalSessionEnded(
            panelId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID
        ) {
            markRemoteTerminalSessionEnded(
                surfaceId: surfaceId,
                relayPort: relayPort,
                allowUntracked: true,
                terminalLifecycleID: terminalLifecycleID,
                terminalLifecycleAlreadyValidated: true
            )
        }
    }

    private func remoteTerminalConnectionTarget(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        allowUntracked: Bool
    ) -> WorkspaceRemoteTerminalConnectionTarget? {
        guard let configuration = remoteConfiguration else {
            guard panels[surfaceId] is TerminalPanel else { return nil }
            return .pending
        }
        let isTracked = activeRemoteTerminalSurfaceIds.contains(surfaceId)
        guard isTracked || allowUntracked,
              authority.matches(configuration) else {
            return nil
        }
        return .configured(isTracked: isTracked)
    }

    /// Commits only bounded lifecycle state while the broker lease is held.
    ///
    /// Presentation and notification work intentionally runs after the lease
    /// is released so those callbacks cannot re-enter broker invalidation.
    private func commitRemoteTerminalSessionConnected(
        target: WorkspaceRemoteTerminalConnectionTarget,
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID?,
        commitLease: (any ControlRemotePTYLifecycleCommitLease)?,
        beforeWorkspaceMutation: @MainActor @Sendable () -> Bool = { true }
    ) -> Bool {
        let applyConnection: @MainActor @Sendable () -> Bool = {
            guard beforeWorkspaceMutation() else { return false }
            switch target {
            case .pending:
                self.pendingRemoteTerminalConnectionsBySurfaceId[surfaceId] =
                    PendingWorkspaceRemoteTerminalConnection(
                        authority: authority,
                        terminalLifecycleID: terminalLifecycleID,
                        commitLease: commitLease
                    )
            case .configured(let isTracked):
                if isTracked {
                    self.remoteTerminalSessionStatesBySurfaceId[surfaceId] =
                        WorkspaceRemoteTerminalSessionState(
                            phase: .connected,
                            authority: authority
                        )
                }
            }
            return true
        }
        let didMutate: Bool
        if let commitLease {
            didMutate = commitLease.commitIfCurrent(applyConnection)
        } else {
            didMutate = applyConnection()
        }
        guard didMutate else { return false }
        if case .configured = target {
            applyRemoteTerminalConnectedPresentation()
        }
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
                authority: connection.authority,
                terminalLifecycleID: connection.terminalLifecycleID,
                commitLease: connection.commitLease
            )
        }
    }

    func clearRemoteTerminalSessionPhase(surfaceId: UUID) {
        remoteTerminalSessionStatesBySurfaceId.removeValue(forKey: surfaceId)
        pendingRemoteTerminalConnectionsBySurfaceId.removeValue(forKey: surfaceId)
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
