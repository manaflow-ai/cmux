import CmuxCore
import CmuxRemoteSession
import Foundation

/// Identifies whether a terminal respawn may cross the remote PTY boundary.
enum RemotePTYRespawnRouting: Equatable {
    case local
    case persistentSSH
    case unsupportedRemote
}

/// The local launch payload and lifecycle identity for one remote respawn.
struct RemotePTYRespawnPlan: Equatable {
    let bridgeCommand: String
    let sessionID: String
    let previousSessionID: String?
    let viewerWorkingDirectory: String
    let rawCommand: String
    /// The command actually delivered to the remote daemon: the raw command,
    /// prefixed with a `cd` when the respawn carried an explicit remote
    /// working directory.
    let remoteCommand: String
}

@MainActor
extension Workspace {
    /// Classifies a respawn target without treating a remote workspace's
    /// untracked/local panes as remote-owned.
    func remotePTYRespawnRouting(panelId: UUID) -> RemotePTYRespawnRouting {
        guard isRemotePTYOwnedSurface(panelId) else { return .local }
        guard let configuration = remoteConfiguration,
              configuration.transport == .ssh,
              configuration.terminalTransport == .ssh,
              configuration.preserveAfterTerminalExit,
              configuration.persistentDaemonSlot != nil,
              !configuration.skipDaemonBootstrap else {
            return .unsupportedRemote
        }
        return .persistentSSH
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
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }
        // `respawn-pane -c <dir>` names a directory in the remote namespace:
        // honor it on the daemon side rather than dropping it (the viewer's
        // local cwd stays the home fallback either way).
        let trimmedRemoteWorkingDirectory = remoteWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteCommand: String
        if let trimmedRemoteWorkingDirectory, !trimmedRemoteWorkingDirectory.isEmpty {
            remoteCommand = "cd \(Self.shellSingleQuoted(trimmedRemoteWorkingDirectory)) && \(trimmedCommand)"
        } else {
            remoteCommand = trimmedCommand
        }

        // The parser accepts the stable `ssh-<workspace>-<panel>` shape. A
        // fresh synthetic panel UUID gives every respawn a new daemon session
        // while retaining workspace inference and relay-alias support.
        let sessionID = Self.defaultSSHPTYSessionID(workspaceId: id, panelId: UUID())
        let previousSessionID = remotePTYSessionIDForRespawnCleanup(panelId: panelId)
        return RemotePTYRespawnPlan(
            bridgeCommand: remotePTYAttachStartupCommand(
                sessionID: sessionID,
                remoteCommand: remoteCommand,
                requireExisting: false
            ),
            sessionID: sessionID,
            previousSessionID: previousSessionID,
            viewerWorkingDirectory: Self.remotePTYViewerWorkingDirectory(),
            rawCommand: trimmedCommand,
            remoteCommand: remoteCommand
        )
    }

    private nonisolated static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        guard let replacement = respawnTerminalSurface(
            panelId: panelId,
            command: plan.bridgeCommand,
            workingDirectory: plan.viewerWorkingDirectory,
            tmuxStartCommand: rawStartCommand.isEmpty ? plan.rawCommand : rawStartCommand,
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
    /// the session, so retrying would spin forever; any other failure
    /// re-parks the request for the next drain.
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
        for (sessionID, owningConfiguration) in pendingRemotePTYSessionCleanups {
            guard remotePTYSessionCleanupTasksBySessionID[sessionID] == nil else { continue }
            guard let controller = remotePTYSessionCleanupController(
                matching: owningConfiguration
            ) else {
                continue
            }
            pendingRemotePTYSessionCleanups.removeValue(forKey: sessionID)
            // RemoteSessionCoordinator is queue-confined and explicitly
            // `@unchecked Sendable`; this task performs only its synchronous,
            // queue-bridged close operation and then reports back to the
            // main actor.
            let task = Task.detached(priority: .utility) { [weak self] in
                let closeError: (any Error)?
                do {
                    try controller.closePTYSession(sessionID: sessionID)
                    closeError = nil
                } catch {
                    closeError = error
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.remotePTYSessionCleanupTasksBySessionID.removeValue(forKey: sessionID)
                    guard closeError != nil else { return }
                    let owningControllerIsLive =
                        self.remoteControllerConnectionState == .connected &&
                        self.remoteConfiguration?.hasSamePersistentPTYIdentity(
                            as: owningConfiguration
                        ) == true
                    guard !owningControllerIsLive else { return }
                    self.pendingRemotePTYSessionCleanups[sessionID] = owningConfiguration
                }
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

    private func remotePTYSessionCleanupController(
        matching owningConfiguration: WorkspaceRemoteConfiguration
    ) -> RemoteSessionCoordinator? {
        if let remoteSessionController,
           remoteConfiguration?.hasSamePersistentPTYIdentity(as: owningConfiguration) == true {
            return remoteSessionController
        }
        return remoteSessionCleanupControllers.values.first {
            $0.configuration.hasSamePersistentPTYIdentity(as: owningConfiguration)
        }?.controller
    }

    private static func remotePTYViewerWorkingDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}
