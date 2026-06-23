public import Foundation

/// Remote PTY session-id bookkeeping for the surface coordinator: the per-
/// surface session-id map, its snapshot/match/discard helpers, and the active-
/// surface tracking predicates. Faithful lift of the `Workspace` PTY-session-id
/// methods. The session-id values themselves are owned by ``state``.
extension RemoteSurfaceCoordinator {
    /// True when `panelId` is currently tracked as an active remote terminal.
    /// Faithful lift of `Workspace.isActiveRemoteTerminalSurface(_:)`.
    public func isActiveRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        state.activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    /// The number of surfaces tracked as active remote terminals. Faithful lift
    /// of `Workspace.activeRemoteTerminalSurfaceCount`.
    public var activeRemoteTerminalSurfaceCount: Int {
        state.activeRemoteTerminalSurfaceIds.count
    }

    /// Marks that the source workspace must not shut down the shared SSH control
    /// master after a detached transfer. Faithful lift of
    /// `Workspace.markSkipControlMasterCleanupAfterDetachedRemoteTransfer()`.
    public func markSkipControlMasterCleanupAfterDetachedRemoteTransfer() {
        state.skipControlMasterCleanupAfterDetachedRemoteTransfer = true
    }

    /// The remote PTY session id to persist for `panelId` in a session snapshot,
    /// or `nil` when the workspace does not preserve PTY sessions or the surface
    /// is not tracked. Faithful lift of
    /// `Workspace.remotePTYSessionIDForSnapshot(panelId:)`.
    public func remotePTYSessionIDForSnapshot(panelId: UUID) -> String? {
        guard let host, host.hostPreservesRemotePTYSession else { return nil }
        if let storedSessionID = host.hostNormalizedRemotePTYSessionID(state.remotePTYSessionIDsByPanelId[panelId]) {
            return storedSessionID
        }
        guard state.activeRemoteTerminalSurfaceIds.contains(panelId) else { return nil }
        return Self.defaultSSHPTYSessionID(workspaceId: host.hostWorkspaceID, panelId: panelId)
    }

    /// Forgets the remote PTY session id for `panelId` (the surface left the
    /// remote workspace). Faithful lift of
    /// `Workspace.discardRemotePTYSessionID(panelId:)`.
    public func discardRemotePTYSessionID(panelId: UUID) {
        state.remotePTYSessionIDsByPanelId.removeValue(forKey: panelId)
        state.endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    /// True when `sessionID` is the remote PTY session id currently expected for
    /// the tracked surface `panelId`. Faithful lift of
    /// `Workspace.remotePTYSessionIDMatches(panelId:sessionID:)`.
    public func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        guard let host,
              state.activeRemoteTerminalSurfaceIds.contains(panelId),
              let normalizedSessionID = host.hostNormalizedRemotePTYSessionID(sessionID) else {
            return false
        }
        let expectedSessionID = host.hostNormalizedRemotePTYSessionID(state.remotePTYSessionIDsByPanelId[panelId])
            ?? Self.defaultSSHPTYSessionID(workspaceId: host.hostWorkspaceID, panelId: panelId)
        return normalizedSessionID == expectedSessionID
    }
}
