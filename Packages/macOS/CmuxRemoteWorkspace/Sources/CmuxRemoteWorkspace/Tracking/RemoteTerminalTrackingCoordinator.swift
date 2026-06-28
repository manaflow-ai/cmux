public import Foundation

public import CmuxCore

/// Per-workspace owner of the remote-terminal tracking and SSH-session-end
/// bookkeeping: the bodies that seed the initial tracked remote terminal, track
/// and untrack remote terminal surfaces, record and end remote PTY attaches, and
/// tear down or demote the remote connection when the last remote terminal exits.
///
/// This lifts the decision/bookkeeping bodies of the legacy `Workspace` methods
/// `seedInitialRemoteTerminalSessionIfNeeded(configuration:)`,
/// `trackRemoteTerminalSurface(_:)`, `untrackRemoteTerminalSurface(_:)`,
/// `discardRemotePTYSessionID(panelId:)`,
/// `remotePTYSessionIDMatches(panelId:sessionID:)`,
/// `markRemotePTYAttachEnded(surfaceId:sessionID:)`,
/// `markPersistentRemotePTYAttachFailed(surfaceId:)`,
/// `maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()`,
/// `cleanupTransferredRemoteConnectionIfNeeded(surfaceId:relayPort:)`,
/// `remoteTerminalSessionEndMatchesCurrentConfiguration(...)`,
/// `disconnectRemoteConnectionAfterTerminalExit()`,
/// `rememberPendingRemoteDisconnectReplacement(configuration:)`,
/// `markRemoteTerminalSessionEnded(surfaceId:relayPort:allowUntracked:)`, and
/// `teardownRemoteConnection()`. The workspace keeps thin forwarders for the
/// externally-called methods so the control-socket, close, panel-lifecycle, and
/// tab-manager callers still resolve.
///
/// The live tracked sets, the published session count, and the lifecycle
/// disconnect bodies stay app-side and are read/written/forwarded through
/// ``RemoteTerminalTrackingHosting``. The localized terminal-exit detail string
/// stays app-side (resolved in the witness so it binds to the app bundle).
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every lifted body was a
/// plain method on the `@MainActor` `Workspace` class, so every read, write, and
/// forward already ran on the main actor. The host reference is weak (the
/// workspace owns the coordinator), so there is no retain cycle.
@MainActor
public final class RemoteTerminalTrackingCoordinator<Host: RemoteTerminalTrackingHosting> {
    private weak var host: Host?

    /// Creates a coordinator. Call ``attach(host:)`` at the composition point
    /// before any remote-terminal tracking orchestration runs.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    /// Seeds the initial tracked remote terminal surface when a remote startup
    /// command is in effect and nothing is tracked yet. Faithful lift of
    /// `Workspace.seedInitialRemoteTerminalSessionIfNeeded(configuration:)`.
    public func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let host else { return }
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard host.hostActiveRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = host.hostNonPlaceholderTerminalPanelIds
        if terminalIds.count == 1, let initialPanelId = terminalIds.first {
            trackRemoteTerminalSurface(initialPanelId)
            return
        }
        if let focusedPanelId = host.hostFocusedPanelId, terminalIds.contains(focusedPanelId) {
            trackRemoteTerminalSurface(focusedPanelId)
        }
    }

    /// Marks `panelId` as a live remote terminal surface, seeding a persistent
    /// session id when configured and applying any pending TTY / port-kick.
    /// Faithful lift of `Workspace.trackRemoteTerminalSurface(_:)`.
    public func trackRemoteTerminalSurface(_ panelId: UUID) {
        guard let host else { return }
        host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer = false
        host.hostRemoveEndedPersistentRemotePTYAttachSurfaceId(panelId)
        host.hostRemovePendingRemoteTerminalChildExitSurfaceId(panelId)
        host.hostTransferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        if host.hostRemoteConfiguration?.preserveAfterTerminalExit == true,
           host.hostNormalizedRemotePTYSessionID(host.hostRemotePTYSessionID(forPanel: panelId)) == nil {
            host.hostSetRemotePTYSessionID(host.hostDefaultSSHPTYSessionID(panelId: panelId), forPanel: panelId)
        }
        guard host.hostInsertActiveRemoteTerminalSurfaceId(panelId) else { return }
        host.hostSyncActiveRemoteTerminalSessionCount()
        host.hostApplyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = host.hostApplyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    /// Drops `panelId` from the live remote terminal set and demotes the remote
    /// workspace if it was the last one. Faithful lift of
    /// `Workspace.untrackRemoteTerminalSurface(_:)`.
    public func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard let host else { return }
        guard host.hostRemoveActiveRemoteTerminalSurfaceId(panelId) else { return }
        host.hostSyncActiveRemoteTerminalSessionCount()
        guard !host.hostIsDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    /// Discards the remote PTY session id and aliases for `panelId`. Faithful
    /// lift of `Workspace.discardRemotePTYSessionID(panelId:)`.
    public func discardRemotePTYSessionID(panelId: UUID) {
        guard let host else { return }
        host.hostRemoveRemotePTYSessionID(forPanel: panelId)
        host.hostRemoveEndedPersistentRemotePTYAttachSurfaceId(panelId)
        host.hostRemoveRemoteRelaySurfaceAliases(targeting: panelId)
    }

    /// Whether the recorded remote PTY session id for `panelId` matches
    /// `sessionID`. Faithful lift of
    /// `Workspace.remotePTYSessionIDMatches(panelId:sessionID:)`.
    public func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        guard let host else { return false }
        return host.hostRemotePTYSessionIDMatches(panelId: panelId, sessionID: sessionID)
    }

    /// Records that the remote PTY attach for `surfaceId` ended, if `sessionID`
    /// matches the expected one, and untracks the surface. Faithful lift of
    /// `Workspace.markRemotePTYAttachEnded(surfaceId:sessionID:)`.
    @discardableResult
    public func markRemotePTYAttachEnded(
        surfaceId: UUID,
        sessionID: String
    ) -> (clearedRemotePTYSession: Bool, untrackedRemoteTerminal: Bool) {
        guard let host else { return (false, false) }
        let normalizedSessionID = host.hostNormalizedRemotePTYSessionID(sessionID)
        let expectedSessionID = host.hostNormalizedRemotePTYSessionID(host.hostRemotePTYSessionID(forPanel: surfaceId))
            ?? host.hostDefaultSSHPTYSessionID(panelId: surfaceId)
        guard let normalizedSessionID, normalizedSessionID == expectedSessionID else {
            return (false, false)
        }

        let wasTracked = host.hostActiveRemoteTerminalSurfaceIds.contains(surfaceId)
        if host.hostRemoteConfiguration?.preserveAfterTerminalExit == true {
            host.hostInsertEndedPersistentRemotePTYAttachSurfaceId(surfaceId)
        } else {
            host.hostRemoveEndedPersistentRemotePTYAttachSurfaceId(surfaceId)
        }
        host.hostRemoveRemotePTYSessionID(forPanel: surfaceId)
        host.hostRemoveRemoteRelaySurfaceAliases(targeting: surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
        return (true, wasTracked)
    }

    /// Clears all remote PTY bookkeeping for `surfaceId` after a persistent
    /// attach failed. Faithful lift of
    /// `Workspace.markPersistentRemotePTYAttachFailed(surfaceId:)`.
    public func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard let host else { return }
        guard host.hostRemoteConfiguration?.preserveAfterTerminalExit == true else { return }

        host.hostRemoveRemotePTYSessionID(forPanel: surfaceId)
        host.hostRemoveEndedPersistentRemotePTYAttachSurfaceId(surfaceId)
        host.hostRemoveRemoteRelaySurfaceAliases(targeting: surfaceId)
        host.hostRemovePendingRemoteTerminalChildExitSurfaceId(surfaceId)
        host.hostTransferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        host.hostRemoveSurfaceTTYName(forPanel: surfaceId)
        if host.hostRemoveActiveRemoteTerminalSurfaceId(surfaceId) {
            host.hostSyncActiveRemoteTerminalSessionCount()
        }
        host.hostSyncRemotePortScanTTYs()
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
    }

    /// Demotes the remote workspace (disconnects, clearing configuration) when no
    /// remote terminals remain and no browser panels keep it alive. Faithful lift
    /// of `Workspace.maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()`.
    public func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard let host else { return }
        guard host.hostActiveRemoteTerminalSurfaceIds.isEmpty, host.hostRemoteConfiguration != nil else { return }
        if host.hostRemoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        let hasBrowserPanels = host.hostHasBrowserPanels
        if !hasBrowserPanels {
            if host.hostRemoteConnectionState == .error ||
                host.hostRemoteDaemonStatus.state == .error ||
                host.hostRemoteConnectionState == .connecting ||
                host.hostRemoteConnectionState == .reconnecting ||
                host.hostRemoteConnectionState == .suspended {
                return
            }
            host.hostDisconnectRemoteConnection(clearConfiguration: true)
        }
    }

    /// Cleans up a transferred remote connection's SSH control master if the
    /// session end matches a recorded transferred-cleanup configuration. Faithful
    /// lift of `Workspace.cleanupTransferredRemoteConnectionIfNeeded(surfaceId:relayPort:)`.
    public func cleanupTransferredRemoteConnectionIfNeeded(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let host else { return false }
        guard let relayPort,
              relayPort > 0,
              let cleanupConfiguration = host.hostTransferredRemoteCleanupConfigurationsByPanelId[surfaceId],
              cleanupConfiguration.relayPort == relayPort else {
            return false
        }
        host.hostTransferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        host.hostRequestSSHControlMasterCleanup(configuration: cleanupConfiguration)
        return true
    }

    /// Whether a remote terminal session end for `surfaceId` matches the current
    /// configuration and relay port. Faithful lift of
    /// `Workspace.remoteTerminalSessionEndMatchesCurrentConfiguration(...)`.
    public func remoteTerminalSessionEndMatchesCurrentConfiguration(
        surfaceId: UUID,
        relayPort: Int?,
        configuration: WorkspaceRemoteConfiguration,
        allowUntracked: Bool
    ) -> Bool {
        guard let host else { return false }
        guard host.hostActiveRemoteTerminalSurfaceIds.contains(surfaceId) ||
            (allowUntracked && host.hostActiveRemoteTerminalSurfaceIds.isEmpty) else {
            return false
        }
        if let relayPort, relayPort > 0 {
            return configuration.relayPort == relayPort
        }
        return true
    }

    /// Disconnects the remote connection after a terminal exit with the localized
    /// terminal-disconnected detail. Faithful lift of
    /// `Workspace.disconnectRemoteConnectionAfterTerminalExit()`; the
    /// `String(localized:)` resolution stays app-side in the witness.
    public func disconnectRemoteConnectionAfterTerminalExit() {
        guard let host else { return }
        host.hostDisconnectRemoteConnectionAfterTerminalExit()
    }

    /// Records the pending remote-disconnect replacement from `configuration` so
    /// the next connect can restore the session. Faithful lift of
    /// `Workspace.rememberPendingRemoteDisconnectReplacement(configuration:)`.
    public func rememberPendingRemoteDisconnectReplacement(configuration: WorkspaceRemoteConfiguration) {
        guard let host else { return }
        let reconnectCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        host.hostPendingRemoteDisconnectReplacement = PendingRemoteDisconnectReplacement(
            target: configuration.displayTarget,
            reconnectCommand: reconnectCommand?.isEmpty == false ? reconnectCommand : nil
        )
    }

    /// Records a remote terminal session end for `surfaceId` and tears down the
    /// remote connection when the last remote terminal exits. Faithful lift of
    /// `Workspace.markRemoteTerminalSessionEnded(surfaceId:relayPort:allowUntracked:)`.
    public func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?, allowUntracked: Bool = false) {
        guard let host else { return }
        if cleanupTransferredRemoteConnectionIfNeeded(surfaceId: surfaceId, relayPort: relayPort) {
            return
        }
        guard let configuration = host.hostRemoteConfiguration,
              remoteTerminalSessionEndMatchesCurrentConfiguration(
                surfaceId: surfaceId,
                relayPort: relayPort,
                configuration: configuration,
                allowUntracked: allowUntracked
              ) else {
            return
        }
        let preservesRemotePTYSession = configuration.preserveAfterTerminalExit
        if !preservesRemotePTYSession {
            rememberPendingRemoteDisconnectReplacement(configuration: configuration)
        }
        host.hostInsertPendingRemoteTerminalChildExitSurfaceId(surfaceId)
        if host.hostRemoveActiveRemoteTerminalSurfaceId(surfaceId) {
            host.hostSyncActiveRemoteTerminalSessionCount()
        }
        if host.hostActiveRemoteTerminalSurfaceIds.isEmpty {
            guard !preservesRemotePTYSession else { return }
            let shouldCleanupControlMaster =
                configuration.relayPort != nil &&
                configuration.transport == .ssh &&
                !host.hostIsDetachingCloseTransaction &&
                host.hostPendingDetachedSurfacesIsEmpty &&
                !host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer
            disconnectRemoteConnectionAfterTerminalExit()
            if shouldCleanupControlMaster {
                host.hostRequestSSHControlMasterCleanup(configuration: configuration)
            }
        }
    }

    /// Tears down the remote connection, clearing configuration. Faithful lift of
    /// `Workspace.teardownRemoteConnection()`.
    public func teardownRemoteConnection() {
        guard let host else { return }
        host.hostDisconnectRemoteConnection(clearConfiguration: true)
    }
}
