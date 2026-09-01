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
        rawCommand: String
    ) -> RemotePTYRespawnPlan? {
        guard remotePTYRespawnRouting(panelId: panelId) == .persistentSSH else {
            return nil
        }
        let trimmedCommand = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        // The parser accepts the stable `ssh-<workspace>-<panel>` shape. A
        // fresh synthetic panel UUID gives every respawn a new daemon session
        // while retaining workspace inference and relay-alias support.
        let sessionID = Self.defaultSSHPTYSessionID(workspaceId: id, panelId: UUID())
        let previousSessionID = remotePTYSessionIDForRespawnCleanup(panelId: panelId)
        return RemotePTYRespawnPlan(
            bridgeCommand: remotePTYAttachStartupCommand(
                sessionID: sessionID,
                remoteCommand: trimmedCommand,
                requireExisting: false
            ),
            sessionID: sessionID,
            previousSessionID: previousSessionID,
            viewerWorkingDirectory: Self.remotePTYViewerWorkingDirectory(),
            rawCommand: trimmedCommand
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
           previousSessionID != plan.sessionID {
            pendingRemotePTYSessionCleanupIDs.insert(previousSessionID)
        }
        drainPendingRemotePTYSessionCleanups()
        return replacement
    }

    /// Closes daemon-side sessions replaced by respawns.
    ///
    /// Cleanup is lifecycle-owned rather than fire-and-forget: a respawn
    /// issued while the workspace is disconnected parks the replaced session
    /// in ``Workspace/pendingRemotePTYSessionCleanupIDs`` and the queue is
    /// re-drained when a controller is available again (respawn, controller
    /// start, explicit reconnect). A close that fails while the workspace has
    /// no connected controller is re-queued for the next drain; a failure
    /// with a live controller is terminal — the daemon no longer knows the
    /// session, so retrying would spin forever.
    func drainPendingRemotePTYSessionCleanups() {
        guard !pendingRemotePTYSessionCleanupIDs.isEmpty else { return }
        if let closeForTesting = remotePTYSessionCloseForTesting {
            let sessionIDs = pendingRemotePTYSessionCleanupIDs
            pendingRemotePTYSessionCleanupIDs.removeAll()
            for sessionID in sessionIDs.sorted() {
                do {
                    try closeForTesting(sessionID)
                } catch {
                    pendingRemotePTYSessionCleanupIDs.insert(sessionID)
                }
            }
            return
        }
        guard let controller = remotePTYSessionCleanupController() else { return }
        let sessionIDs = pendingRemotePTYSessionCleanupIDs
        pendingRemotePTYSessionCleanupIDs.removeAll()
        for sessionID in sessionIDs {
            // RemoteSessionCoordinator is queue-confined and explicitly
            // `@unchecked Sendable`; this detached task performs only its
            // synchronous, queue-bridged close operation.
            _ = Task.detached(priority: .utility) { [weak self] in
                do {
                    try controller.closePTYSession(sessionID: sessionID)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.remoteControllerConnectionState != .connected else {
                            return
                        }
                        self.pendingRemotePTYSessionCleanupIDs.insert(sessionID)
                    }
                }
            }
        }
    }

    private func isRemotePTYOwnedSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId) ||
            remoteDisconnectPlaceholderPanelIds.contains(panelId) ||
            pendingRemoteTerminalChildExitSurfaceIds.contains(panelId)
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

    private func remotePTYSessionCleanupController() -> RemoteSessionCoordinator? {
        if let remoteSessionController {
            return remoteSessionController
        }
        guard let remoteConfiguration else { return nil }
        return remoteSessionCleanupControllers.values.first {
            $0.configuration.hasSamePersistentPTYIdentity(as: remoteConfiguration)
        }?.controller
    }

    private static func remotePTYViewerWorkingDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}
