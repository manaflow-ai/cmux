import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import Foundation

@MainActor
extension Workspace {
    func enqueueRemoteSessionTransition(
        targetConfiguration: WorkspaceRemoteConfiguration?,
        shouldStartController: Bool,
        finalCleanup: Bool
    ) {
        let transitionID = UUID()
        let precedingTransition = remoteSessionTransitionTask
        remoteSessionTransitionID = transitionID
        remoteSessionTransitionTask = Task { @MainActor [weak self] in
            await precedingTransition?.value
            guard let self else { return }
            await performRemoteSessionTransition(
                id: transitionID,
                targetConfiguration: targetConfiguration,
                shouldStartController: shouldStartController,
                finalCleanup: finalCleanup
            )
        }
    }

    private func performRemoteSessionTransition(
        id: UUID,
        targetConfiguration: WorkspaceRemoteConfiguration?,
        shouldStartController: Bool,
        finalCleanup: Bool
    ) async {
        guard remoteSessionTransitionID == id else { return }
        let cleanupOwners = remoteSessionCleanupControllers
        var blockingCleanupFailed = false
        for (controllerID, owner) in cleanupOwners {
            let hasSamePersistentIdentity = targetConfiguration.map {
                owner.configuration.hasSamePersistentPTYIdentity(as: $0)
            } == true
            let hasConflictingRelayResources = targetConfiguration.map {
                owner.configuration.hasSameRemoteRelayNamespace(as: $0)
            } == true
            let cleanupScope: RemoteRelayCleanupScope
            if targetConfiguration != nil {
                cleanupScope = hasSamePersistentIdentity ? .transport : .persistentSlot
            } else {
                cleanupScope = finalCleanup ? .persistentSlot : .transport
            }
            guard remoteSessionTransitionID == id else { return }
            guard remoteSessionCleanupControllers[controllerID]?.controller === owner.controller else { continue }
            let succeeded: Bool
            switch cleanupScope {
            case .transport:
                succeeded = await owner.controller.stopAndWait(cleanupScope: .transport)
            case .persistentSlot:
                _ = await owner.controller.stopAndWait(cleanupScope: .transport)
                guard remoteSessionTransitionID == id else { return }
                guard remoteSessionCleanupControllers[controllerID]?.controller === owner.controller else { continue }
                succeeded = await owner.controller.stopAndWait(cleanupScope: .persistentSlot)
            }
            guard remoteSessionCleanupControllers[controllerID]?.controller === owner.controller else { continue }
            if succeeded {
                nativeSSHConnectionBroker.releaseWorkspace(owner.configuration)
                if owner.configuration.persistentDaemonSlot == nil {
                    remoteSessionCleanupControllers.removeValue(forKey: controllerID)
                } else if case .persistentSlot = cleanupScope {
                    remoteSessionCleanupControllers.removeValue(forKey: controllerID)
                }
            }
            guard remoteSessionTransitionID == id else { return }
            if !succeeded, hasSamePersistentIdentity || hasConflictingRelayResources {
                blockingCleanupFailed = true
            }
        }

        guard remoteSessionTransitionID == id else { return }
        defer {
            remoteSessionTransitionID = nil
            remoteSessionTransitionTask = nil
        }
        guard shouldStartController,
              let targetConfiguration,
              remoteConfiguration == targetConfiguration else {
            return
        }
        guard !blockingCleanupFailed else {
            remoteConnectionState = .error
            applyBrowserRemoteWorkspaceStatusToPanels()
            postRemoteConnectionPresentationDidChange()
            return
        }

        // The completed transport cleanup and replacement now form one ownership handoff.
        remoteSessionCleanupControllers = remoteSessionCleanupControllers.filter {
            !$0.value.configuration.hasSamePersistentPTYIdentity(as: targetConfiguration)
        }
        startRemoteSessionController(configuration: targetConfiguration)
    }

    private func startRemoteSessionController(configuration: WorkspaceRemoteConfiguration) {
        let controllerID = UUID()
        var processRunner: any RemoteSessionProcessRunning = RemoteSessionProcessRunner()
#if DEBUG
        if let override = remoteSessionProcessRunnerOverrideForTesting { processRunner = override }
#endif
        let controller = RemoteSessionCoordinator(
            host: WorkspaceRemoteSessionHostAdapter(workspace: self, controllerID: controllerID),
            configuration: configuration,
            proxyBroker: TerminalController.shared.remoteProxyBroker,
            connectionBroker: nativeSSHConnectionBroker,
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            processRunner: processRunner,
            reachabilityProbe: RemoteHostReachabilityProbe(),
            relayCommandRewriter: WorkspaceRemoteRelayCommandRewriter(),
            buildInfo: WorkspaceRemoteSessionBuildInfo(),
            daemonStrings: RemoteDaemonStrings.appLocalized,
            strings: RemoteSessionStrings.appLocalized
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.updateRemotePortScanningEnabled(Self.remotePortScanningEnabledFromSettings())
        syncRemotePortScanTTYs()
        syncRemoteRelayIDAliasesToController()
        controller.start()
    }

    @discardableResult
    func reconnectRemoteConnection(surfaceId: UUID? = nil) -> Bool {
        guard let configuration = remoteConfiguration else { return false }
        var didRespawnTerminal = false
        let reconnectingSurfaceId: UUID?
        if let surfaceId {
            guard panels[surfaceId] is TerminalPanel else { return false }
            reconnectingSurfaceId = surfaceId
        } else {
            reconnectingSurfaceId = remoteReconnectTerminalSurfaceId(requestedSurfaceId: nil)
        }
        if configuration.preserveAfterTerminalExit {
            let reattached = reattachPersistentRemotePTYPanels(requestedSurfaceId: surfaceId, restartEndedSessions: true)
            didRespawnTerminal = surfaceId.map(reattached.contains) ?? !reattached.isEmpty
        } else if let startupCommand = effectiveRemoteTerminalStartupCommand(from: configuration),
                  !startupCommand.isEmpty,
                  let reconnectingSurfaceId {
            let shouldRespawnSurface = isDefaultFreestyleSSHDRemoteWorkspace ||
                surfaceId != nil ||
                remoteDisconnectPlaceholderPanelIds.contains(reconnectingSurfaceId) ||
                pendingRemoteTerminalChildExitSurfaceIds.contains(reconnectingSurfaceId) ||
                !activeRemoteTerminalSurfaceIds.contains(reconnectingSurfaceId) ||
                activeRemoteTerminalSurfaceIds.isEmpty ||
                remoteConnectionState != .connected
            if shouldRespawnSurface {
                didRespawnTerminal = respawnTerminalSurface(
                    panelId: reconnectingSurfaceId,
                    command: startupCommand,
                    tmuxStartCommand: startupCommand,
                    waitAfterCommand: true
                ) != nil
            }
            if didRespawnTerminal {
                remoteDisconnectPlaceholderPanelIds.remove(reconnectingSurfaceId)
                pendingRemoteTerminalChildExitSurfaceIds.remove(reconnectingSurfaceId)
                pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: reconnectingSurfaceId)
            }
            if didRespawnTerminal || !shouldRespawnSurface { trackRemoteTerminalSurface(reconnectingSurfaceId) }
        }
        if reconnectingSurfaceId != nil, remoteConnectionState == .connected { return didRespawnTerminal }
        guard remoteConnectionState != .connecting, remoteConnectionState != .reconnecting else { return didRespawnTerminal }
        configureRemoteConnection(configuration, autoConnect: true)
        return didRespawnTerminal
    }

    @discardableResult
    func reconnectCloudTerminalSurface(surfaceId: UUID) -> Bool {
        guard isManagedCloudVMWorkspace,
              isRemoteTerminalSurface(surfaceId) || remoteDisconnectPlaceholderPanelIds.contains(surfaceId) else {
            return false
        }
        return reconnectRemoteConnection(surfaceId: surfaceId)
    }

    private func remoteReconnectTerminalSurfaceId(requestedSurfaceId: UUID?) -> UUID? {
        if let requestedSurfaceId, panels[requestedSurfaceId] is TerminalPanel { return requestedSurfaceId }
        if let focusedPanelId, panels[focusedPanelId] is TerminalPanel { return focusedPanelId }
        let terminalPanelIds = panels.compactMap { panelId, panel in panel is TerminalPanel ? panelId : nil }
        return terminalPanelIds.count == 1 ? terminalPanelIds.first : nil
    }

    nonisolated static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else { return }
        guard let remoteConfiguration else {
            remoteForegroundAuthenticationPhase = .readyBeforeConfiguration(token: foregroundAuthToken)
            return
        }
        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken,
              remoteForegroundAuthenticationPhase == .authenticating(token: foregroundAuthToken) else {
            return
        }
        remoteForegroundAuthenticationPhase = nil
        configureRemoteConnection(remoteConfiguration, autoConnect: true)
    }
}
