public import Foundation

public import CmuxCore

/// The live-workspace seam the ``RemoteConnectionLifecycleCoordinator`` reaches
/// back through to read and push the slice of workspace state its top-level
/// remote connection-lifecycle orchestrators touch.
///
/// The coordinator owns the orchestration bodies of the legacy `Workspace`
/// methods `configureRemoteConnection(_:autoConnect:)`,
/// `reconnectRemoteConnection(surfaceId:)`,
/// `notifyRemoteForegroundAuthenticationReady(token:)`,
/// `disconnectRemoteConnection(clearConfiguration:disconnectedDetail:)`, and
/// `clearRemoteConfigurationIfWorkspaceBecameLocal()`. Everything those bodies
/// read or mutate that cannot move down a module boundary is reproduced here as
/// one read or push.
///
/// Many members are intentionally identical to requirements of the sibling
/// `RemoteStatusHosting`, `RemoteSurfaceHosting`, `RemoteSurfaceTTYHosting`, and
/// `RemoteTerminalTrackingHosting` seams: `Workspace` conforms to all of them, so
/// one shared witness implementation satisfies every seam. The published-state
/// reset surface (`hostRemoteConnectionState`/`Detail`, `hostRemoteDaemonStatus`,
/// `hostRemoteProxyEndpoint`, `hostRemoteHeartbeatCount`,
/// `hostRemoteLastHeartbeatAt`, `hostRemoteDetectedPorts`/`ForwardedPorts`/
/// `PortConflicts`, the three error-dedup fingerprints, the status-entry keys and
/// removal, `hostRecomputeListeningPorts`, `hostApplyBrowserRemoteWorkspaceStatusToPanels`)
/// is reused from `RemoteStatusHosting`; the tracked-state flags
/// (`hostSkipControlMasterCleanupAfterDetachedRemoteTransfer`,
/// `hostPendingRemoteDisconnectReplacement`,
/// `hostRequestSSHControlMasterCleanup`) from `RemoteTerminalTrackingHosting`; and
/// the pending TTY / port-kick fields from `RemoteSurfaceTTYHosting`.
///
/// The single live `RemoteSessionCoordinator` is constructed and started app-side
/// behind ``hostMakeAndStartRemoteSession(configuration:controllerID:)`` (its
/// dependency graph names `TerminalController.shared`,
/// `WorkspaceRemoteSessionHostAdapter`, `RemoteDaemonManifestRepository`, the
/// `*.appLocalized` localized strings, and the DEBUG test-runner override, none of
/// which can move down a module boundary) and torn down behind
/// ``hostStopRemoteSession()``. The seed/track forwards re-enter the sibling
/// `RemoteTerminalTrackingCoordinator` through the host so the two coordinators
/// stay decoupled.
///
/// `@MainActor` for the same reason as the sibling seams: every lifted body was a
/// plain method on the `@MainActor` `Workspace`, so all of its reads, writes, and
/// pushes already ran on the main actor. The coordinator never imports the
/// `Workspace` type; it is witnessed in
/// `Workspace+RemoteConnectionLifecycleHosting.swift`.
@MainActor
public protocol RemoteConnectionLifecycleHosting: AnyObject {
    /// The port-scan kick reason type (the app's `PortScanKickReason`, which lives
    /// in a package above this one). Only ever set to `nil` here, so the concrete
    /// type never needs to be named. Identical to the sibling
    /// `RemoteSurfaceTTYHosting.PortKickReason`.
    associatedtype PortKickReason

    // MARK: - Remote configuration

    /// The current remote configuration. Set on configure (to the new
    /// configuration) and on disconnect-with-clear (to `nil`). Shared with the
    /// sibling seams' read-only views.
    var hostRemoteConfiguration: WorkspaceRemoteConfiguration? { get set }

    // MARK: - Published remote-status reset surface (shared with RemoteStatusHosting)

    /// The published remote connection state.
    var hostRemoteConnectionState: WorkspaceRemoteConnectionState { get set }

    /// The published remote connection detail string.
    var hostRemoteConnectionDetail: String? { get set }

    /// The published remote daemon status.
    var hostRemoteDaemonStatus: WorkspaceRemoteDaemonStatus { get set }

    /// The published remote proxy endpoint.
    var hostRemoteProxyEndpoint: BrowserProxyEndpoint? { get set }

    /// The published remote heartbeat count.
    var hostRemoteHeartbeatCount: Int { get set }

    /// The published timestamp of the last remote heartbeat.
    var hostRemoteLastHeartbeatAt: Date? { get set }

    /// The published detected remote ports.
    var hostRemoteDetectedPorts: [Int] { get set }

    /// The published forwarded remote ports.
    var hostRemoteForwardedPorts: [Int] { get set }

    /// The published remote port conflicts.
    var hostRemotePortConflicts: [Int] { get set }

    /// The remote-status error-dedup fingerprint.
    var hostRemoteLastErrorFingerprint: String? { get set }

    /// The remote-daemon error-dedup fingerprint.
    var hostRemoteLastDaemonErrorFingerprint: String? { get set }

    /// The remote port-conflict error-dedup fingerprint.
    var hostRemoteLastPortConflictFingerprint: String? { get set }

    /// The sidebar status-entry key for the remote error.
    var hostRemoteErrorStatusKey: String { get }

    /// The sidebar status-entry key for remote port conflicts.
    var hostRemotePortConflictStatusKey: String { get }

    /// Removes the sidebar status entry for `key`.
    func hostRemoveRemoteStatusEntry(forKey key: String)

    /// Recomputes the workspace's listening-port snapshot (slice 1).
    func hostRecomputeListeningPorts()

    /// Re-applies the browser remote-workspace status to the live panels (slice 2).
    func hostApplyBrowserRemoteWorkspaceStatusToPanels()

    /// Applies a remote proxy-endpoint update through the remote-status
    /// coordinator (slice 2). Only ever called with `nil` here.
    func hostApplyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?)

    /// Clears the per-surface detected remote ports through the remote-status
    /// coordinator (slice 2).
    func hostClearRemoteDetectedSurfacePorts()

    // MARK: - Detach / cleanup flags (shared with RemoteTerminalTrackingHosting)

    /// Whether a detach-close transaction is in progress.
    var hostIsDetachingCloseTransaction: Bool { get }

    /// Whether the pending-detached-surfaces map is empty.
    var hostPendingDetachedSurfacesIsEmpty: Bool { get }

    /// Whether to skip SSH control-master cleanup after a detached remote
    /// transfer.
    var hostSkipControlMasterCleanupAfterDetachedRemoteTransfer: Bool { get set }

    /// The pending remote-disconnect replacement to apply on next connect.
    var hostPendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement? { get set }

    /// Requests SSH control-master cleanup for `configuration` if needed (slice 1).
    func hostRequestSSHControlMasterCleanup(configuration: WorkspaceRemoteConfiguration)

    // MARK: - Pending surface TTY / port-kick (shared with RemoteSurfaceTTYHosting)

    /// The pending remote-surface TTY name.
    var hostPendingRemoteSurfaceTTYName: String? { get set }

    /// The pending remote-surface TTY surface id.
    var hostPendingRemoteSurfaceTTYSurfaceId: UUID? { get set }

    /// The pending remote-surface port-kick reason.
    var hostPendingRemoteSurfacePortKickReason: PortKickReason? { get set }

    /// The pending remote-surface port-kick surface id.
    var hostPendingRemoteSurfacePortKickSurfaceId: UUID? { get set }

    // MARK: - Foreground auth token

    /// The pending remote foreground-authentication token to consume on the next
    /// matching configure.
    var hostPendingRemoteForegroundAuthToken: String? { get set }

    // MARK: - Remote-disconnect placeholder panel ids

    /// The remote-disconnect placeholder panel ids.
    var hostRemoteDisconnectPlaceholderPanelIds: Set<UUID> { get }

    /// Remote terminal child-exit panel ids that may be reconnected in place.
    var hostPendingRemoteTerminalChildExitSurfaceIds: Set<UUID> { get }

    /// Subtracts `ids` from the remote-disconnect placeholder set.
    func hostSubtractRemoteDisconnectPlaceholderPanelIds(_ ids: Set<UUID>)

    /// Removes `id` from the remote-disconnect placeholder set.
    func hostRemoveRemoteDisconnectPlaceholderPanelId(_ id: UUID)

    /// Clears the remote-disconnect placeholder set.
    func hostClearRemoteDisconnectPlaceholderPanelIds()

    // MARK: - Tracked-set / relay clears

    /// Clears the live remote terminal surface set.
    func hostClearActiveRemoteTerminalSurfaceIds()

    /// Clears the ended-persistent remote PTY-attach surface set.
    func hostClearEndedPersistentRemotePTYAttachSurfaceIds()

    /// Resets the published remote-terminal session count to zero.
    func hostResetActiveRemoteTerminalSessionCount()

    /// Removes every recorded remote PTY session id.
    func hostRemoveAllRemotePTYSessionIDs()

    /// Clears the reverse-CLI-relay workspace/surface id alias maps.
    func hostClearRemoteRelayIDAliases()

    // MARK: - Panel probes

    /// Whether the live panel for `panelId` is a terminal panel.
    func hostIsTerminalPanel(_ panelId: UUID) -> Bool

    /// Whether the live panel map is empty.
    var hostPanelsIsEmpty: Bool { get }

    // MARK: - Sibling-coordinator forwards

    /// Seeds the initial tracked remote terminal surface for `configuration`
    /// (re-enters the sibling `RemoteTerminalTrackingCoordinator`, slice 4).
    func hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration)

    /// Marks `panelId` as a live remote terminal surface (re-enters the sibling
    /// `RemoteTerminalTrackingCoordinator`, slice 4).
    func hostTrackRemoteTerminalSurface(_ panelId: UUID)

    // MARK: - Live session construction (stays app-side)

    /// Constructs and starts the single live `RemoteSessionCoordinator` for
    /// `configuration` under `controllerID`, recording it as the active controller.
    /// Stays app-side because its dependency graph names symbols that cannot move
    /// down a module boundary.
    func hostMakeAndStartRemoteSession(configuration: WorkspaceRemoteConfiguration, controllerID: UUID)

    /// Stops and clears the active live `RemoteSessionCoordinator`.
    func hostStopRemoteSession()

    /// Notifies the remote-PTY controller that its availability changed (the
    /// `TerminalController.shared` call stays app-side).
    func hostNotifyRemotePTYControllerAvailabilityChanged()
}
