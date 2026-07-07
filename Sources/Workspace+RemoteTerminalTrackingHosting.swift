import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// `Workspace` is the live host for its `RemoteTerminalTrackingCoordinator`. The
/// coordinator (in `CmuxRemoteWorkspace`) owns the remote-terminal tracking and
/// SSH-session-end bookkeeping bodies; this witness reproduces the slice of live
/// workspace state those bodies mutate that the sibling seams do not already
/// expose.
///
/// The read-only views of the tracked sets and remote state
/// (`hostActiveRemoteTerminalSurfaceIds`, the ended/pending sets,
/// `hostRemoteConfiguration`, `hostRemoteConnectionState`,
/// `hostRemoteDaemonStatus`, `hostIsDetachingCloseTransaction`,
/// `hostFocusedPanelId`, `hostNormalizedRemotePTYSessionID`,
/// `hostSyncRemotePortScanTTYs`, `hostApplyBrowserRemoteWorkspaceStatusToPanels`)
/// are already witnessed by the sibling `Workspace+RemoteSurfaceHosting`,
/// `Workspace+RemoteStatusHosting`, `Workspace+RemoteRelaySessionHosting`, and
/// `Workspace+RemoteSurfaceTTYHosting` extensions; `Workspace` conforms to all of
/// those seams, so those single implementations satisfy this seam too and are not
/// repeated here. This file only adds the tracked-set mutations, the published
/// session-count resync (kept behind a co-located helper so the count keeps its
/// `private(set)` encapsulation), the flag / pending-replacement get/set, the
/// panel-map probes, and the relay / lifecycle forwards the tracking coordinator
/// needs. The localized terminal-exit detail string resolves here so it binds to
/// the app bundle.
///
/// The coordinator is held by `Workspace` and references this host weakly, so
/// there is no retain cycle.
extension Workspace: RemoteTerminalTrackingHosting {
    // MARK: - Tracked-set mutations

    @discardableResult
    func hostInsertActiveRemoteTerminalSurfaceId(_ id: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.insert(id).inserted
    }

    @discardableResult
    func hostRemoveActiveRemoteTerminalSurfaceId(_ id: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.remove(id) != nil
    }

    func hostSyncActiveRemoteTerminalSessionCount() {
        syncActiveRemoteTerminalSessionCount()
    }

    func hostInsertEndedPersistentRemotePTYAttachSurfaceId(_ id: UUID) {
        endedPersistentRemotePTYAttachSurfaceIds.insert(id)
    }

    func hostRemoveEndedPersistentRemotePTYAttachSurfaceId(_ id: UUID) {
        endedPersistentRemotePTYAttachSurfaceIds.remove(id)
    }

    func hostInsertPendingRemoteTerminalChildExitSurfaceId(_ id: UUID) {
        pendingRemoteTerminalChildExitSurfaceIds.insert(id)
    }

    func hostRemovePendingRemoteTerminalChildExitSurfaceId(_ id: UUID) {
        pendingRemoteTerminalChildExitSurfaceIds.remove(id)
    }

    var hostTransferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] {
        get { transferredRemoteCleanupConfigurationsByPanelId }
        set { transferredRemoteCleanupConfigurationsByPanelId = newValue }
    }

    // MARK: - Flags and pending replacement

    var hostSkipControlMasterCleanupAfterDetachedRemoteTransfer: Bool {
        get { skipControlMasterCleanupAfterDetachedRemoteTransfer }
        set { skipControlMasterCleanupAfterDetachedRemoteTransfer = newValue }
    }

    var hostPendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement? {
        get { pendingRemoteDisconnectReplacement }
        set { pendingRemoteDisconnectReplacement = newValue }
    }

    // MARK: - Panel probes

    var hostNonPlaceholderTerminalPanelIds: [UUID] {
        panels.compactMap { panelId, panel in
            panel is TerminalPanel && !remoteDisconnectPlaceholderPanelIds.contains(panelId)
                ? panelId
                : nil
        }
    }

    var hostHasBrowserPanels: Bool {
        panels.values.contains { $0 is BrowserPanel }
    }

    var hostPendingDetachedSurfacesIsEmpty: Bool {
        pendingDetachedSurfaces.isEmpty
    }

    // MARK: - Per-surface TTY names

    func hostRemoveSurfaceTTYName(forPanel panelId: UUID) {
        surfaceTTYNames.removeValue(forKey: panelId)
    }

    // MARK: - Relay session forwards

    func hostRemotePTYSessionID(forPanel panelId: UUID) -> String? {
        remoteRelaySession.remotePTYSessionID(forPanel: panelId)
    }

    func hostSetRemotePTYSessionID(_ sessionID: String, forPanel panelId: UUID) {
        remoteRelaySession.setRemotePTYSessionID(sessionID, forPanel: panelId)
    }

    func hostRemoveRemotePTYSessionID(forPanel panelId: UUID) {
        remoteRelaySession.removeRemotePTYSessionID(forPanel: panelId)
    }

    func hostRemoveRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        remoteRelaySession.removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    func hostRemotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        remoteRelaySession.remotePTYSessionIDMatches(panelId: panelId, sessionID: sessionID)
    }

    func hostDefaultSSHPTYSessionID(panelId: UUID) -> String {
        Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }

    // MARK: - Sibling-coordinator forwards

    func hostApplyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
    }

    @discardableResult
    func hostApplyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        remoteSurfaceTTYCoordinator.applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    // MARK: - Lifecycle disconnect forwards (in-file, slice 5)

    func hostDisconnectRemoteConnection(clearConfiguration: Bool) {
        disconnectRemoteConnection(clearConfiguration: clearConfiguration)
    }

    func hostDisconnectRemoteConnectionAfterTerminalExit() {
        disconnectRemoteConnection(
            clearConfiguration: false,
            disconnectedDetail: String(
                localized: "remote.status.terminalDisconnected",
                defaultValue: "Remote terminal session disconnected"
            )
        )
    }

    func hostRequestSSHControlMasterCleanup(configuration: WorkspaceRemoteConfiguration) {
        Self.requestSSHControlMasterCleanupIfNeeded(configuration: configuration)
    }
}
