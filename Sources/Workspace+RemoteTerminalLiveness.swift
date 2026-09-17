import CmuxControlSocket
import CmuxCore
import Foundation

// This file keeps the closed lifecycle vocabulary beside its only behavior
// owner; these value types have no independent state, dependencies, or callers.
enum WorkspaceRemoteTerminalSessionPhase: Equatable {
    case launching
    case connected
    case ended
}

enum WorkspaceRemoteTerminalAuthority: Equatable, Sendable {
    case relayPort(Int)
    case persistentTransport(String)

    var preservesRemotePTYAcrossAttachAttempts: Bool {
        if case .persistentTransport = self { return true }
        return false
    }

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
    let terminalLifecycleID: UUID?
}

struct PendingWorkspaceRemoteTerminalConnection {
    let authority: WorkspaceRemoteTerminalAuthority
    let terminalLifecycleID: UUID?
    let attemptID: UUID?
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
        in externalDocks: [DockSplitStore],
        excludingSurfaceId: UUID? = nil
    ) -> Bool {
        guard let configuration = remoteConfiguration else { return false }
        let hasConnectedWorkspaceSurface = activeRemoteTerminalSurfaceIds.contains {
            guard $0 != excludingSurfaceId else { return false }
            guard let state = remoteTerminalSessionStatesBySurfaceId[$0] else { return false }
            return state.phase == .connected && state.authority.matches(configuration)
        }
        let workspaceDockIsConnected = _dockSplit?.hasAuthoritativelyConnectedRemoteTerminal(
            presentationWorkspaceID: id,
            configuration: configuration,
            excludingPanelId: excludingSurfaceId
        ) == true
        let externalDockIsConnected = externalDocks.contains {
            $0.hasAuthoritativelyConnectedRemoteTerminal(
                presentationWorkspaceID: id,
                configuration: configuration,
                excludingPanelId: excludingSurfaceId
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
        let terminalLifecycleID = (panels[surfaceId] as? TerminalPanel)?
            .surface.terminalLifecycleId
        if let terminalLifecycleID,
           endedRemoteTerminalLifecycleIDsBySurfaceId[surfaceId] == terminalLifecycleID {
            return
        }
        if terminalLifecycleID != nil {
            endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: surfaceId)
        }
        let previousState = remoteTerminalSessionStatesBySurfaceId[surfaceId]
        if previousState == nil || previousState?.terminalLifecycleID != terminalLifecycleID {
            invalidateReportedSurfaceTTYRuntime(panelId: surfaceId)
        }
        remoteTerminalSessionStatesBySurfaceId[surfaceId] = WorkspaceRemoteTerminalSessionState(
            phase: .launching,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID
        )
    }

    @discardableResult
    func markRemoteTerminalSessionLaunching(
        surfaceId: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID
    ) -> Bool {
        guard let terminalPanel = panels[surfaceId] as? TerminalPanel,
              terminalPanel.surface.terminalLifecycleId == terminalLifecycleID,
              endedRemoteTerminalLifecycleIDsBySurfaceId[surfaceId] != terminalLifecycleID else {
            return false
        }
        endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: surfaceId)
        if remoteTerminalAttemptIDsBySurfaceId[surfaceId] != attemptID,
           (activeRemoteTerminalSurfaceIds.contains(surfaceId)
                ? remoteConfiguration
                : transferredRemoteCleanupConfigurationsByPanelId[surfaceId])?
                .preserveAfterTerminalExit != true {
            invalidateReportedSurfaceTTYRuntime(panelId: surfaceId)
        }
        remoteTerminalAttemptIDsBySurfaceId[surfaceId] = attemptID
        markRemoteTerminalSessionLaunching(surfaceId: surfaceId)
        applyRemoteTerminalLaunchingPresentation()
        return true
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
        attemptID: UUID? = nil,
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
            allowUntracked: allowUntracked,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID
        ) else {
            return false
        }
        return commitRemoteTerminalSessionConnected(
            target: target,
            surfaceId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID,
            commitLease: commitLease
        )
    }

    func markDockRemoteTerminalSessionLaunching(
        surfaceId: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID,
        dock: DockSplitStore
    ) -> Bool {
        guard dock.ownsRemoteTerminalTransfer(
                  panelId: surfaceId,
                  presentationWorkspaceID: id
              ),
              endedRemoteTerminalLifecycleIDsBySurfaceId[surfaceId] !=
                terminalLifecycleID,
              dock.markRemoteTerminalSessionLaunching(
                  panelId: surfaceId,
                  terminalLifecycleID: terminalLifecycleID,
                  attemptID: attemptID
              ) else {
            return false
        }
        endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: surfaceId)
        remoteTerminalAttemptIDsBySurfaceId[surfaceId] = attemptID
        applyRemoteTerminalLaunchingPresentation()
        return true
    }

    func markDockRemoteTerminalSessionConnected(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        terminalLifecycleID: UUID? = nil,
        attemptID: UUID? = nil,
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
                  allowUntracked: true,
                  terminalLifecycleID: terminalLifecycleID,
                  attemptID: attemptID
              ) else {
            return false
        }
        return commitRemoteTerminalSessionConnected(
            target: target,
            surfaceId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID,
            commitLease: commitLease,
            beforeWorkspaceMutation: {
                dock.markRemoteTerminalSessionConnected(
                    panelId: surfaceId,
                    authority: authority,
                    terminalLifecycleID: terminalLifecycleID,
                    attemptID: attemptID
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
        let didEnd = dock.markRemoteTerminalSessionEnded(
            panelId: surfaceId,
            authority: authority,
            terminalLifecycleID: terminalLifecycleID
        ) {
            markRemoteTerminalSessionEnded(
                surfaceId: surfaceId,
                relayPort: relayPort,
                allowUntracked: true,
                terminalLifecycleID: terminalLifecycleID,
                terminalLifecycleAlreadyValidated: true,
                deferPresentationReconciliationUntilDockCommit: true,
                recordLifecycleTombstone: false,
                livenessExcludingSurfaceId: surfaceId
            )
        }
        if didEnd {
            reconcileRemoteTerminalPresentationAfterSessionEnd()
        }
        return didEnd
    }

    private func remoteTerminalConnectionTarget(
        surfaceId: UUID,
        authority: WorkspaceRemoteTerminalAuthority,
        allowUntracked: Bool,
        terminalLifecycleID: UUID?,
        attemptID: UUID?
    ) -> WorkspaceRemoteTerminalConnectionTarget? {
        if let terminalLifecycleID,
           endedRemoteTerminalLifecycleIDsBySurfaceId[surfaceId] ==
            terminalLifecycleID {
            return nil
        }
        if let attemptID,
           remoteTerminalAttemptIDsBySurfaceId[surfaceId] != attemptID {
            return nil
        }
        if let endedState = remoteTerminalSessionStatesBySurfaceId[surfaceId],
           endedState.phase == .ended {
            guard let terminalLifecycleID,
                  let endedLifecycleID = endedState.terminalLifecycleID,
                  terminalLifecycleID != endedLifecycleID else {
                return nil
            }
        }
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
        attemptID: UUID?,
        commitLease: (any ControlRemotePTYLifecycleCommitLease)?,
        beforeWorkspaceMutation: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> Bool {
        let applyConnection: @MainActor @Sendable () -> Bool = {
            guard beforeWorkspaceMutation() else { return false }
            switch target {
            case .pending:
                self.pendingRemoteTerminalConnectionsBySurfaceId[surfaceId] =
                    PendingWorkspaceRemoteTerminalConnection(
                        authority: authority,
                        terminalLifecycleID: terminalLifecycleID,
                        attemptID: attemptID,
                        commitLease: commitLease
                    )
            case .configured(let isTracked):
                if isTracked {
                    self.remoteTerminalSessionStatesBySurfaceId[surfaceId] =
                        WorkspaceRemoteTerminalSessionState(
                            phase: .connected,
                            authority: authority,
                            terminalLifecycleID: terminalLifecycleID
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
        clearRecoveredRemoteDaemonSidebarArtifacts()
        applyBrowserRemoteWorkspaceStatusToPanels()
        postRemoteConnectionPresentationDidChange()
    }

    private func applyRemoteTerminalLaunchingPresentation() {
        guard remoteConfiguration != nil,
              !hasAuthoritativelyConnectedRemoteTerminal(
                  in: DockSplitStore.liveRemoteTerminalStores(
                      presentationWorkspaceID: id
                  )
              ) else {
            return
        }
        remoteConnectionState =
            remoteConnectionState == .connected || remoteConnectionState == .reconnecting
            ? .reconnecting
            : .connecting
        remoteConnectionDetail = nil
        applyBrowserRemoteWorkspaceStatusToPanels()
        postRemoteConnectionPresentationDidChange()
    }

    func reconcileRemoteTerminalPresentationAfterSessionEnd() {
        guard remoteConfiguration != nil,
              !hasAuthoritativelyConnectedRemoteTerminal(
                  in: DockSplitStore.liveRemoteTerminalStores(
                      presentationWorkspaceID: id
                  )
              ) else {
            return
        }
        let wasPresentedConnected = remoteConnectionState == .connected
        let hasLaunchingTerminal = activeRemoteTerminalSurfaceIds.contains {
            remoteTerminalSessionStatesBySurfaceId[$0]?.phase == .launching
        }
        if remoteControllerConnectionState == .error ||
            remoteControllerConnectionState == .suspended {
            applyRemoteConnectionStateUpdate(
                remoteControllerConnectionState,
                detail: remoteControllerConnectionDetail,
                target: remoteDisplayTarget ?? "remote host",
                externalRemoteTerminalDocks:
                    DockSplitStore.liveRemoteTerminalStores(
                        presentationWorkspaceID: id
                    )
            )
            return
        }
        switch remoteControllerConnectionState {
        case .connected:
            remoteConnectionState =
                wasPresentedConnected || hasLaunchingTerminal
                ? .reconnecting
                : .connecting
        case .disconnected where hasLaunchingTerminal:
            remoteConnectionState =
                wasPresentedConnected ? .reconnecting : .connecting
        default:
            remoteConnectionState = remoteControllerConnectionState
        }
        remoteConnectionDetail = remoteControllerConnectionDetail
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
                attemptID: connection.attemptID,
                commitLease: connection.commitLease
            )
        }
    }

    func clearRemoteTerminalSessionPhase(surfaceId: UUID) {
        invalidateReportedSurfaceTTYRuntime(panelId: surfaceId)
        surfaceRegistry.remoteTTYReportOriginWorkspaceIDs.removeValue(forKey: surfaceId)
        remoteTerminalSessionStatesBySurfaceId.removeValue(forKey: surfaceId)
        pendingRemoteTerminalConnectionsBySurfaceId.removeValue(forKey: surfaceId)
        remoteTerminalAttemptIDsBySurfaceId.removeValue(forKey: surfaceId)
    }

    func clearActiveRemoteTerminalSessionPhases() {
        for surfaceId in activeRemoteTerminalSurfaceIds {
            clearRemoteTerminalSessionPhase(surfaceId: surfaceId)
        }
        activeRemoteTerminalSurfaceIds.removeAll()
    }

    func restoreRemoteTerminalSessionPhase(
        _ phase: WorkspaceRemoteTerminalSessionPhase?,
        authority: WorkspaceRemoteTerminalAuthority?,
        terminalLifecycleID: UUID?,
        attemptID: UUID?,
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
            WorkspaceRemoteTerminalSessionState(
                phase: phase,
                authority: authority,
                terminalLifecycleID: terminalLifecycleID
            )
        if let attemptID {
            remoteTerminalAttemptIDsBySurfaceId[surfaceId] = attemptID
        }
        if phase == .connected {
            applyRemoteTerminalConnectedPresentation()
        }
    }
}
