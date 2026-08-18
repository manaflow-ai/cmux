import Foundation

extension Workspace {
    func prepareRemoteSessionForSystemSleep() {
        remotePTYSessionControllerForSocketCommand()?.prepareForSystemSleep()
    }

    func rearmRemoteSessionAfterSystemWake() {
        forceRemoteSessionReconnectRetry(reason: "system wake")
    }

    /// Re-arms the remote session's reconnect policy through one shared path.
    ///
    /// `resetReconnectPolicyLocked` only schedules when the coordinator is
    /// suspended, retrying, missing a proxy endpoint, or has no ready daemon, so
    /// a healthy connection is left alone.
    func forceRemoteSessionReconnectRetry(reason: String) {
#if DEBUG
        // The coordinator logs `remote.session.reconnect.rearmed`, but not which
        // entrypoint asked; without this a reconnect storm cannot be attributed to
        // system wake versus a user action. Logged before the controller lookup so a
        // request that finds no controller is still visible.
        cmuxDebugLog(
            "remote.session.forceReconnect workspace=\(id.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        remotePTYSessionControllerForSocketCommand()?.resetReconnectPolicyAndReconnect(
            reason: reason
        )
    }

    /// True when a persistent remote attach is running or retrying but has never
    /// published a ready bridge for this surface.
    ///
    /// Every wrapper attempt registers `workspace.remote.terminal_session_launching`
    /// and only a ready bridge reaches `.connected`, so "not connected" is the
    /// failing-or-pending signal. During the wrapper's foreground-auth phase no
    /// launching attempt is registered at all, which is why this cannot test for
    /// `.launching`.
    func isPersistentRemoteAttachAwaitingReadiness(_ panelId: UUID) -> Bool {
        guard remoteConfiguration?.preserveAfterTerminalExit == true,
              terminalPanel(for: panelId) != nil,
              activeRemoteTerminalSurfaceIds.contains(panelId) else { return false }
        return remoteTerminalSessionStatesBySurfaceId[panelId]?.phase != .connected
    }

    /// True for panes the shared reattach path can act on.
    ///
    /// A persistent pane may be reattached while its wrapper is still alive:
    /// respawning HUPs the wrapper, which retires only its lifecycle generation
    /// and leaves the remote PTY running.
    func canReattachRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        guard terminalPanel(for: panelId) != nil, remoteConfiguration != nil else { return false }
        return remoteDisconnectPlaceholderPanelIds.contains(panelId)
            || pendingRemoteTerminalChildExitSurfaceIds.contains(panelId)
            || endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
            || isPersistentRemoteAttachAwaitingReadiness(panelId)
    }

    func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return }
        let previousPresentedDirectory = presentedCurrentDirectory
        let sessionEnded = endedPersistentRemotePTYAttachSurfaceIds.contains(surfaceId)
        if !sessionEnded {
            remotePTYSessionIDsByPanelId[surfaceId] = persistentRemotePTYSessionIDForRestart(panelId: surfaceId)
        }
        remoteDisconnectPlaceholderPanelIds.insert(surfaceId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(surfaceId)
        cancelPendingRemoteDisconnectReplacement(surfaceId: surfaceId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        surfaceTTYNames.removeValue(forKey: surfaceId)
        let removedTrustedDirectory = clearRemoteDirectoryReportForPersistentPTYFailure(surfaceId: surfaceId)
        if !sessionEnded { trackRemoteTerminalSurface(surfaceId) }
        syncRemotePortScanTTYs()
        refreshPersistentPTYFailurePresentation(
            previousDirectory: previousPresentedDirectory,
            removedTrustedDirectory: removedTrustedDirectory
        )
    }

    /// Replaces dead persistent-PTY panels with require-existing attach wrappers.
    @discardableResult
    func reattachPersistentRemotePTYPanels(
        requestedSurfaceId: UUID? = nil,
        restartEndedSessions: Bool = false,
        includesLiveFailingAttaches: Bool = false
    ) -> Set<UUID> {
        guard let configuration = remoteConfiguration,
              configuration.preserveAfterTerminalExit == true else { return [] }
        var candidateIDs = requestedSurfaceId.map { Set([$0]) } ?? remoteDisconnectPlaceholderPanelIds
        // Default false so the automatic `.connected` transition cannot let a sibling
        // pane's connect event respawn a pane still working through its first attempt.
        if requestedSurfaceId == nil, includesLiveFailingAttaches {
            candidateIDs.formUnion(pendingRemoteTerminalChildExitSurfaceIds)
            candidateIDs.formUnion(activeRemoteTerminalSurfaceIds.filter {
                isPersistentRemoteAttachAwaitingReadiness($0)
            })
        }
        var reattached = Set<UUID>()

        for panelId in candidateIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard terminalPanel(for: panelId) != nil,
                  remoteDisconnectPlaceholderPanelIds.contains(panelId) ||
                    pendingRemoteTerminalChildExitSurfaceIds.contains(panelId) ||
                    activeRemoteTerminalSurfaceIds.contains(panelId) else {
                continue
            }
            let sessionID = persistentRemotePTYSessionIDForRestart(panelId: panelId)
            let resumeBinding = surfaceResumeBindingsByPanelId[panelId]
            let sessionEnded = endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
            guard restartEndedSessions || !sessionEnded else { continue }
            let command: String
            let usesPersistentSSHPTY = configuration.transport == .ssh &&
                !configuration.skipDaemonBootstrap && configuration.persistentDaemonSlot != nil
            if usesPersistentSSHPTY {
                let approvedResumeCommand = approvedPersistentSSHResumeCommand(
                    for: resumeBinding,
                    panelID: panelId,
                    persistentPTYSessionID: sessionID
                )
                let restartedShellCommand = sessionEnded
                    ? configuration.relayPort.map {
                        SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(
                            relayPort: $0,
                            configuredRemoteCommand: configuration.configuredRemoteCommand
                        )
                    }
                    : nil
                command = remotePTYAttachStartupCommand(
                    sessionID: sessionID,
                    remoteCommand: approvedResumeCommand ?? restartedShellCommand,
                    requireExisting: !sessionEnded
                )
            } else {
                guard let startupCommand = effectiveRemoteTerminalStartupCommand(from: configuration) else {
                    continue
                }
                command = startupCommand
            }
            guard respawnTerminalSurface(
                panelId: panelId,
                command: command,
                tmuxStartCommand: command,
                waitAfterCommand: true
            ) != nil else {
                continue
            }

            remotePTYSessionIDsByPanelId[panelId] = sessionID
            registerRemoteRelayIDAliases(remotePTYSessionID: sessionID, restoredPanelId: panelId)
            if let resumeBinding {
                surfaceResumeBindingsByPanelId[panelId] = resumeBinding
            }
            remoteDisconnectPlaceholderPanelIds.remove(panelId)
            pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
            pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: panelId)
            endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
            trackRemoteTerminalSurface(panelId)
            reattached.insert(panelId)
        }
        return reattached
    }

    private func persistentRemotePTYSessionIDForRestart(panelId: UUID) -> String {
        if let mappedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) {
            return mappedSessionID
        }
        if let inheritedSessionID = normalizedRemotePTYSessionID(
            terminalPanel(for: panelId)?.surface.respawnAdditionalEnvironment[Self.remotePTYSessionEnvironmentKey]
        ) {
            return inheritedSessionID
        }
        return Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }
}
