import CmuxCore
import CmuxRemoteSession
import CmuxRemoteWorkspace
import Foundation

@MainActor
extension Workspace {
    /// Classifies a respawn target without treating a remote workspace's
    /// untracked/local panes as remote-owned.
    func remotePTYRespawnRouting(panelId: UUID) -> RemotePTYRespawnRouting {
        RemotePTYRespawnPlanner().routing(
            isRemoteOwned: isRemotePTYOwnedSurface(panelId),
            configuration: remoteConfiguration
        )
    }

    /// Builds a remote-owned respawn payload while keeping the raw command out
    /// of the local Ghostty executable slot.
    func remotePTYRespawnPlan(
        panelId: UUID,
        rawCommand: String,
        remoteWorkingDirectory: String? = nil
    ) -> RemotePTYRespawnPlan? {
        guard remotePTYRespawnRouting(panelId: panelId) == .persistentSSH else {
            return nil
        }
        let sessionID = RemotePTYRespawnPlanner.defaultSessionID(
            workspaceID: id,
            panelID: UUID()
        )
        return RemotePTYRespawnPlanner().plan(
            sessionID: sessionID,
            rawCommand: rawCommand,
            remoteWorkingDirectory: remoteWorkingDirectory,
            previousSessionID: remotePTYSessionIDForRespawnCleanup(panelId: panelId)
        )
    }

    /// Replaces a remote-owned panel with a local viewer for a fresh remote PTY.
    /// The prior daemon session is closed asynchronously on its owning
    /// coordinator so the main actor never waits on network I/O.
    @discardableResult
    func respawnRemotePTYSurface(
        panelId: UUID,
        plan: RemotePTYRespawnPlan,
        rawStartCommand: String,
        focus: Bool?,
        allowTextBoxFocusDefault: Bool
    ) -> TerminalPanel? {
        // A command-less `respawn-pane -k` replays the stored start command
        // verbatim, so when the respawn carried an explicit remote working
        // directory the persisted command must be the cd-prefixed variant or
        // the directory would be lost on replay.
        let persistedStartCommand: String
        if plan.remoteCommand != plan.rawCommand {
            persistedStartCommand = plan.remoteCommand
        } else if rawStartCommand.isEmpty {
            persistedStartCommand = plan.rawCommand
        } else {
            persistedStartCommand = rawStartCommand
        }
        let bridgeCommand = remotePTYAttachStartupCommand(
            sessionID: plan.sessionID,
            remoteCommand: plan.remoteCommand,
            requireExisting: false
        )
        guard let replacement = respawnTerminalSurface(
            panelId: panelId,
            command: bridgeCommand,
            workingDirectory: Self.remotePTYViewerWorkingDirectory(),
            tmuxStartCommand: persistedStartCommand,
            focus: focus,
            waitAfterCommand: true,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ) else {
            return nil
        }

        // `respawnTerminalSurface` intentionally discards the old panel's
        // lifecycle state. Re-register the replacement only after the panel
        // identity is mounted, then publish the fresh session alias.
        remotePTYSessionIDsByPanelId[panelId] = plan.sessionID
        registerRemoteRelayIDAliases(
            remotePTYSessionID: plan.sessionID,
            restoredPanelId: panelId
        )
        remoteDisconnectPlaceholderPanelIds.remove(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        trackRemoteTerminalSurface(panelId)

        if let previousSessionID = plan.previousSessionID,
           previousSessionID != plan.sessionID,
           let owningConfiguration = remoteConfiguration {
            pendingRemotePTYSessionCleanups[previousSessionID] = owningConfiguration
        }
        drainPendingRemotePTYSessionCleanups()
        return replacement
    }

    /// Closes daemon-side sessions replaced by respawns.
    ///
    /// Cleanup is lifecycle-owned rather than fire-and-forget: a respawn
    /// issued while the workspace is disconnected parks the replaced session
    /// in ``Workspace/pendingRemotePTYSessionCleanups`` together with the
    /// persistent-PTY identity that owns it, and the queue is re-drained when
    /// a controller is available again (respawn, controller start, explicit
    /// reconnect). Each request only ever drains through a controller whose
    /// configuration matches the owning identity, so a workspace that has
    /// since moved to a different host keeps the request parked instead of
    /// closing (and discarding) the ID against the wrong daemon. In-flight
    /// closes are retained in
    /// ``Workspace/remotePTYSessionCleanupTasksBySessionID``, which also
    /// serializes per-session drains. A close that fails while the owning
    /// identity's controller is live is terminal — the daemon no longer knows
    /// the session, so retrying would spin forever; a queue-handoff timeout is
    /// the exception because the RPC never started, and is re-parked for the
    /// next drain.
    func drainPendingRemotePTYSessionCleanups() {
        guard !pendingRemotePTYSessionCleanups.isEmpty else { return }
        #if DEBUG
        if let closeForTesting = remotePTYSessionCloseForTesting {
            let entries = pendingRemotePTYSessionCleanups
            pendingRemotePTYSessionCleanups.removeAll()
            for sessionID in entries.keys.sorted() {
                do {
                    try closeForTesting(sessionID)
                } catch {
                    pendingRemotePTYSessionCleanups[sessionID] = entries[sessionID]
                }
            }
            return
        }
        #endif
        let pendingEntries = pendingRemotePTYSessionCleanups
        var controllersByIdentity: [
            String: (controller: RemoteSessionCoordinator, configuration: WorkspaceRemoteConfiguration)
        ] = [:]
        for owner in remoteSessionCleanupControllers.values {
            for key in owner.configuration.persistentPTYIdentityLookupKeys {
                controllersByIdentity[key] = owner
            }
        }
        if let remoteSessionController,
           let currentConfiguration = remoteConfiguration {
            for key in currentConfiguration.persistentPTYIdentityLookupKeys {
                controllersByIdentity[key] = (
                    controller: remoteSessionController,
                    configuration: currentConfiguration
                )
            }
        }

        for (sessionID, owningConfiguration) in pendingEntries {
            guard remotePTYSessionCleanupTasksBySessionID[sessionID] == nil else { continue }
            var matchedOwner: (
                controller: RemoteSessionCoordinator,
                configuration: WorkspaceRemoteConfiguration
            )?
            for key in owningConfiguration.persistentPTYIdentityLookupKeys {
                guard let candidate = controllersByIdentity[key],
                      candidate.configuration.hasSamePersistentPTYIdentity(as: owningConfiguration) else {
                    continue
                }
                matchedOwner = candidate
                break
            }
            guard let matchedOwner else {
                continue
            }
            pendingRemotePTYSessionCleanups.removeValue(forKey: sessionID)
            // The coordinator's async close schedules the RPC on its own
            // queue, so this task suspends instead of blocking a cooperative
            // Swift-concurrency worker on the legacy synchronous bridge.
            let task = Task {
                @MainActor [weak self, controller = matchedOwner.controller, sessionID, owningConfiguration] in
                let closeError: (any Error)?
                do {
                    try await controller.closePTYSessionAsync(sessionID: sessionID)
                    closeError = nil
                } catch {
                    closeError = error
                }
                guard let self else { return }
                self.remotePTYSessionCleanupTasksBySessionID.removeValue(forKey: sessionID)
                guard closeError != nil else { return }
                let owningControllerIsLive =
                    self.remoteControllerConnectionState == .connected &&
                    self.remoteConfiguration?.hasSamePersistentPTYIdentity(
                        as: owningConfiguration
                    ) == true
                let queueHandoffTimedOut: Bool
                if let closeError {
                    let nsError = closeError as NSError
                    queueHandoffTimedOut =
                        nsError.domain == "cmux.remote.pty" && nsError.code == 8
                } else {
                    queueHandoffTimedOut = false
                }
                // Code 8 means the coordinator queue never started the close;
                // retain the request even when the old controller still looks
                // connected so a later lifecycle transition can retry it.
                guard !owningControllerIsLive || queueHandoffTimedOut else { return }
                self.pendingRemotePTYSessionCleanups[sessionID] = owningConfiguration
            }
            remotePTYSessionCleanupTasksBySessionID[sessionID] = task
        }
    }

    private func isRemotePTYOwnedSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId) ||
            remoteDisconnectPlaceholderPanelIds.contains(panelId) ||
            pendingRemoteTerminalChildExitSurfaceIds.contains(panelId) ||
            // An ended persistent PTY untracks the surface but the panel is
            // still remote-owned: a respawn must mint a fresh remote session,
            // never fall through to a local exec of the remote command.
            endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
    }

    private func remotePTYSessionIDForRespawnCleanup(panelId: UUID) -> String? {
        if let mapped = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) {
            return mapped
        }
        if let inherited = normalizedRemotePTYSessionID(
            terminalPanel(for: panelId)?.surface.respawnAdditionalEnvironment[Self.remotePTYSessionEnvironmentKey]
        ) {
            return inherited
        }
        guard isRemotePTYOwnedSurface(panelId) else { return nil }
        return Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }

    private static func remotePTYViewerWorkingDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}
