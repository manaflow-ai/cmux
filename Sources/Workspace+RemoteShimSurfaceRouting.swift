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
        // If a previous remote session was tracked for this pane, end it before
        // registering the replacement.  Persistent daemon sessions survive detach
        // for up to 24 hours by design; without an explicit close the replaced
        // session would linger as an orphan until the idle-reap TTL fires.
        let previousSessionID = remotePTYSessionIDsByPanelId[panelId]
        let isReplacing = previousSessionID != nil && previousSessionID != sessionID
        if let previousSessionID, isReplacing {
            // Clear relay aliases for the old session.  We do NOT call
            // markRemotePTYAttachEnded here because that function calls
            // untrackRemoteTerminalSurface, which would transiently empty
            // activeRemoteTerminalSurfaceIds and cascade to
            // maybeDemoteRemoteWorkspaceAfterSSHSessionEnded →
            // disconnectRemoteConnection(clearConfiguration: true), killing the
            // workspace mid-respawn.  The guard in markRemotePTYAttachEnded also
            // fires on the old session ID only when it still equals the map entry,
            // so reordering (registering the new ID first) would silently no-op it.
            // The two pieces of markRemotePTYAttachEnded the replaced-session case
            // genuinely needs are:
            //   1. removeRemoteRelaySurfaceAliases — clears stale relay routing
            //      entries for the old session so the new one is unambiguous.
            //   2. closeRemotePTYSession — daemon-side kill of the orphaned session.
            // The third piece (untrackRemoteTerminalSurface) must be skipped: the
            // pane stays tracked because it is being immediately re-registered.
            // The endedPersistentRemotePTYAttachSurfaceIds bookkeeping is also
            // skipped: that flag marks a *terminated* pane; respawn is the opposite.
            removeRemoteRelaySurfaceAliases(targeting: panelId)
            // Best-effort daemon-side kill.  closeRemotePTYSession throws when
            // the remote connection is not active (e.g. in unit tests or after
            // disconnect); swallow those errors silently.
            try? closeRemotePTYSession(sessionID: previousSessionID)
        }
        remotePTYSessionIDsByPanelId[panelId] = sessionID
        registerRemoteRelayIDAliases(remotePTYSessionID: sessionID, restoredPanelId: panelId)
        remoteDisconnectPlaceholderPanelIds.remove(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        pendingRemoteDisconnectReplacementsBySurfaceId.removeValue(forKey: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        trackRemoteTerminalSurface(panelId)
        return isReplacing ? previousSessionID : nil
    }
}
