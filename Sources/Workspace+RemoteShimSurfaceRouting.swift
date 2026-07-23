import Foundation

struct RemoteShimRespawnRewrite: Equatable {
    let command: String
    let sessionID: String
}

extension Workspace {
    /// Reroutes shim/relay respawns of remote-tracked surfaces onto a fresh
    /// daemon-owned pty session on the remote host. nil = surface is local;
    /// caller proceeds with the ordinary local respawn.
    func remoteShimRespawnRewrite(panelId: UUID, rawCommand: String) -> RemoteShimRespawnRewrite? {
        guard remoteConfiguration != nil else { return nil }
        guard isRemoteTerminalSurface(panelId)
            || activeRemoteTerminalSurfaceIds.contains(panelId)
            || remoteDisconnectPlaceholderPanelIds.contains(panelId) else { return nil }
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Fresh ID per respawn: reusing the deterministic reattach ID would
        // join the pane's previous session instead of starting this command.
        let sessionID = "shim-\(id.uuidString)-\(panelId.uuidString)-\(UUID().uuidString)"
        let command = remotePTYAttachStartupCommand(
            sessionID: sessionID,
            remoteCommand: trimmed,
            requireExisting: false
        )
        return RemoteShimRespawnRewrite(command: command, sessionID: sessionID)
    }

    /// Same post-respawn bookkeeping the persistent-PTY reattach path does
    /// (Workspace+PersistentRemotePTYReattach.swift:86-95).
    ///
    /// Returns the previous session ID for the pane, if one was tracked before
    /// this respawn replaced it, or nil if the pane had no prior remote session.
    @discardableResult
    func applyRemoteShimRespawnBookkeeping(panelId: UUID, sessionID: String) -> String? {
        remotePTYSessionIDsByPanelId[panelId] = sessionID
        registerRemoteRelayIDAliases(remotePTYSessionID: sessionID, restoredPanelId: panelId)
        remoteDisconnectPlaceholderPanelIds.remove(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        trackRemoteTerminalSurface(panelId)
        return nil
    }
}
