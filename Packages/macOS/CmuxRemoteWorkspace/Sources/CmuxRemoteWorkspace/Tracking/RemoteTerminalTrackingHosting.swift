public import Foundation

public import CmuxCore

/// The live-workspace seam the ``RemoteTerminalTrackingCoordinator`` reaches back
/// through to read and push the slice of workspace state its remote-terminal
/// tracking and session-end bodies touch.
///
/// The coordinator owns the decision/bookkeeping logic of the remote-terminal
/// surface tracking, remote PTY-attach bookkeeping, and SSH-session-end teardown
/// paths. Everything those bodies read or mutate that cannot move down a module
/// boundary is reproduced here as one read or push.
///
/// Several read-only members (`hostActiveRemoteTerminalSurfaceIds`,
/// `hostEndedPersistentRemotePTYAttachSurfaceIds`,
/// `hostPendingRemoteTerminalChildExitSurfaceIds`, `hostRemoteConfiguration`,
/// `hostRemoteConnectionState`, `hostRemoteDaemonStatus`,
/// `hostIsDetachingCloseTransaction`, `hostFocusedPanelId`,
/// `hostNormalizedRemotePTYSessionID`, `hostSyncRemotePortScanTTYs`,
/// `hostApplyBrowserRemoteWorkspaceStatusToPanels`) are intentionally identical to
/// requirements of the sibling `RemoteSurfaceHosting` / `RemoteStatusHosting` /
/// `RemoteRelaySessionHosting` / `RemoteSurfaceTTYHosting` seams: `Workspace`
/// conforms to all of them, so one shared witness implementation satisfies every
/// seam. The tracked-set mutations the coordinator performs are exposed as their
/// own insert/remove methods (rather than `{ get set }`) so they do not collide
/// with the sibling seams' read-only views of the same sets.
///
/// `@MainActor` for the same reason as the sibling seams: every lifted body was a
/// plain method on the `@MainActor` `Workspace`, so all of its reads, writes, and
/// pushes already ran on the main actor. The coordinator never imports the
/// `Workspace` type; it is witnessed in `Workspace+RemoteTerminalTrackingHosting.swift`.
@MainActor
public protocol RemoteTerminalTrackingHosting: AnyObject {
    // MARK: - Tracked-set reads (shared with sibling seams)

    /// The set of surface ids with live remote terminals.
    var hostActiveRemoteTerminalSurfaceIds: Set<UUID> { get }

    /// Surface ids whose persistent remote PTY attach has ended.
    var hostEndedPersistentRemotePTYAttachSurfaceIds: Set<UUID> { get }

    /// Surface ids with a pending remote-terminal child exit.
    var hostPendingRemoteTerminalChildExitSurfaceIds: Set<UUID> { get }

    // MARK: - Tracked-set mutations

    /// Inserts `id` into the live remote terminal set; returns whether it was
    /// newly inserted.
    @discardableResult
    func hostInsertActiveRemoteTerminalSurfaceId(_ id: UUID) -> Bool

    /// Removes `id` from the live remote terminal set; returns whether it was
    /// present.
    @discardableResult
    func hostRemoveActiveRemoteTerminalSurfaceId(_ id: UUID) -> Bool

    /// Resyncs the published `activeRemoteTerminalSessionCount` to
    /// `activeRemoteTerminalSurfaceIds.count`, keeping its `private(set)`
    /// encapsulation and published `didSet`.
    func hostSyncActiveRemoteTerminalSessionCount()

    /// Inserts `id` into the ended-persistent-attach set.
    func hostInsertEndedPersistentRemotePTYAttachSurfaceId(_ id: UUID)

    /// Removes `id` from the ended-persistent-attach set.
    func hostRemoveEndedPersistentRemotePTYAttachSurfaceId(_ id: UUID)

    /// Inserts `id` into the pending-child-exit set.
    func hostInsertPendingRemoteTerminalChildExitSurfaceId(_ id: UUID)

    /// Removes `id` from the pending-child-exit set.
    func hostRemovePendingRemoteTerminalChildExitSurfaceId(_ id: UUID)

    /// The per-panel transferred-remote cleanup configurations.
    var hostTransferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] { get set }

    // MARK: - Flags and pending replacement

    /// Whether to skip SSH control-master cleanup after a detached remote
    /// transfer.
    var hostSkipControlMasterCleanupAfterDetachedRemoteTransfer: Bool { get set }

    /// The pending remote-disconnect replacement to apply on next connect.
    var hostPendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement? { get set }

    // MARK: - Remote state reads (shared with sibling seams)

    /// The current remote configuration, or `nil`.
    var hostRemoteConfiguration: WorkspaceRemoteConfiguration? { get }

    /// The current remote connection state.
    var hostRemoteConnectionState: WorkspaceRemoteConnectionState { get }

    /// The current remote daemon status.
    var hostRemoteDaemonStatus: WorkspaceRemoteDaemonStatus { get }

    /// Whether a detach-close transaction is in progress.
    var hostIsDetachingCloseTransaction: Bool { get }

    /// The currently focused panel id, or `nil`.
    var hostFocusedPanelId: UUID? { get }

    // MARK: - Panel probes

    /// The non-placeholder terminal panel ids, in panel-map order. Derived
    /// app-side because it reaches the live panel map, the `TerminalPanel` type,
    /// and the remote-disconnect placeholder set.
    var hostNonPlaceholderTerminalPanelIds: [UUID] { get }

    /// Whether any live panel is a browser panel.
    var hostHasBrowserPanels: Bool { get }

    /// Whether the pending-detached-surfaces map is empty.
    var hostPendingDetachedSurfacesIsEmpty: Bool { get }

    // MARK: - Per-surface TTY names

    /// Removes the recorded TTY name for `panelId`.
    func hostRemoveSurfaceTTYName(forPanel panelId: UUID)

    // MARK: - Relay session forwards

    /// The recorded remote PTY session id for `panelId`.
    func hostRemotePTYSessionID(forPanel panelId: UUID) -> String?

    /// Records `sessionID` as the remote PTY session id for `panelId`.
    func hostSetRemotePTYSessionID(_ sessionID: String, forPanel panelId: UUID)

    /// Removes the recorded remote PTY session id for `panelId`.
    func hostRemoveRemotePTYSessionID(forPanel panelId: UUID)

    /// Removes the relay surface aliases targeting `panelId`.
    func hostRemoveRemoteRelaySurfaceAliases(targeting panelId: UUID)

    /// Whether the recorded remote PTY session id for `panelId` matches
    /// `sessionID`.
    func hostRemotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool

    /// Normalizes a remote PTY session id (trims, drops empties). Shared with the
    /// sibling `RemoteRelaySessionHosting` seam.
    func hostNormalizedRemotePTYSessionID(_ value: String?) -> String?

    /// The default SSH PTY session id for `panelId` in this workspace.
    func hostDefaultSSHPTYSessionID(panelId: UUID) -> String

    // MARK: - Sibling-coordinator forwards

    /// Applies a pending remote-surface TTY name to `panelId` (slice 3).
    func hostApplyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID)

    /// Applies a pending remote-surface port-kick to `panelId` (slice 3).
    @discardableResult
    func hostApplyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool

    /// Re-syncs the remote port-scan TTY list. Shared with the sibling
    /// `RemoteSurfaceTTYHosting` seam.
    func hostSyncRemotePortScanTTYs()

    /// Re-applies the browser remote-workspace status to the live panels. Shared
    /// with the sibling `RemoteStatusHosting` seam.
    func hostApplyBrowserRemoteWorkspaceStatusToPanels()

    // MARK: - Lifecycle disconnect forwards (in-file, slice 5)

    /// Disconnects the remote connection, optionally clearing configuration.
    func hostDisconnectRemoteConnection(clearConfiguration: Bool)

    /// Disconnects the remote connection after a terminal exit with the localized
    /// terminal-disconnected detail (the `String(localized:)` stays app-side).
    func hostDisconnectRemoteConnectionAfterTerminalExit()

    /// Requests SSH control-master cleanup for `configuration` if needed.
    func hostRequestSSHControlMasterCleanup(configuration: WorkspaceRemoteConfiguration)
}
