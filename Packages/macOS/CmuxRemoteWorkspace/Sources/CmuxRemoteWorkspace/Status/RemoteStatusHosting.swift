public import CmuxCore
public import Foundation

/// The live-workspace seam the ``RemoteStatusCoordinator`` reaches back through
/// to read and push the slice of workspace state its remote publish-side status
/// apply bodies touch.
///
/// The coordinator owns the decision/bookkeeping logic of the six remote-status
/// apply paths (connection state, daemon status, proxy endpoint, heartbeat,
/// detected-port snapshot, and the detected-port clear). Everything those bodies
/// read or mutate that cannot move down a module boundary is reproduced here as
/// one read or push:
///
/// - the published remote-status stored state (connection state/detail, daemon
///   status, proxy endpoint, heartbeat count and timestamp, detected/forwarded
///   ports, port conflicts, and the tracked detected-surface id set), each
///   witnessed get/set so the workspace's `didSet` Combine bridges still fire;
/// - the per-surface listening-port map (mutated in place, key by key, exactly
///   as the legacy bodies did);
/// - the sidebar status entries (`remote.error` / `remote.port_conflicts`) and
///   the sidebar log, both owned by the workspace's sidebar metadata model;
/// - the three error-dedup fingerprints (also reset on connect/disconnect, so
///   they stay app-side rather than moving into the coordinator);
/// - the slice-1 pure decision reads (`preservesProxyFailureWhileSSHTerminalIsAlive`,
///   `hasProxyOnlyRemoteSidebarError`), the notification cooldown key/interval,
///   and the resolved localized suspended copy;
/// - the browser-panel fan-out and listening-port recompute, which touch
///   app-target panel types and so run on the host.
///
/// `@MainActor` for the same reason as the sibling seams: every lifted body was
/// a plain method on the `@MainActor` `Workspace`, so all of its reads, writes,
/// and pushes already ran on the main actor. The coordinator never imports the
/// `Workspace` type; it is witnessed in `Workspace+RemoteStatusHosting.swift`.
@MainActor
public protocol RemoteStatusHosting: AnyObject {
    // MARK: - Published remote-status stored state (witnessed get/set)

    /// The effective remote connection state. Setting it fires the workspace's
    /// `remoteConnectionState` `didSet` Combine bridge.
    var hostRemoteConnectionState: WorkspaceRemoteConnectionState { get set }

    /// The latest remote connection detail string. Setting it fires the
    /// `remoteConnectionDetail` `didSet` Combine bridge.
    var hostRemoteConnectionDetail: String? { get set }

    /// The latest remote daemon status. Setting it fires the `remoteDaemonStatus`
    /// `didSet` Combine bridge.
    var hostRemoteDaemonStatus: WorkspaceRemoteDaemonStatus { get set }

    /// The current browser proxy endpoint published for the workspace.
    var hostRemoteProxyEndpoint: BrowserProxyEndpoint? { get set }

    /// The most recent remote heartbeat count (already clamped at the write site).
    var hostRemoteHeartbeatCount: Int { get set }

    /// The timestamp of the most recent remote heartbeat, or `nil`.
    var hostRemoteLastHeartbeatAt: Date? { get set }

    /// The detected remote listening ports.
    var hostRemoteDetectedPorts: [Int] { get set }

    /// The forwarded remote ports.
    var hostRemoteForwardedPorts: [Int] { get set }

    /// The remote port conflicts.
    var hostRemotePortConflicts: [Int] { get set }

    /// The set of surface ids currently tracked as having detected remote ports.
    var hostRemoteDetectedSurfaceIds: Set<UUID> { get set }

    // MARK: - Per-surface listening ports (in-place mutation)

    /// Drops the listening-port entry for `panelId`. Faithful equivalent of
    /// `surfaceListeningPorts.removeValue(forKey: panelId)`.
    func hostRemoveSurfaceListeningPorts(forPanel panelId: UUID)

    /// Records `ports` as the listening ports for `panelId`. Faithful equivalent
    /// of `surfaceListeningPorts[panelId] = ports`.
    func hostSetSurfaceListeningPorts(_ ports: [Int], forPanel panelId: UUID)

    /// Recomputes the fused workspace listening-port projection.
    func hostRecomputeListeningPorts()

    // MARK: - Sidebar status entries and log

    /// The sidebar status-entry key for the remote SSH/proxy error banner
    /// (`remote.error`).
    var hostRemoteErrorStatusKey: String { get }

    /// The sidebar status-entry key for the remote port-conflict banner
    /// (`remote.port_conflicts`).
    var hostRemotePortConflictStatusKey: String { get }

    /// Sets the sidebar status entry for `key` with `value` and `icon` (color
    /// `nil`, timestamp now), matching the legacy `SidebarStatusEntry`
    /// construction byte for byte.
    func hostSetRemoteStatusEntry(forKey key: String, value: String, icon: String)

    /// Removes the sidebar status entry for `key`.
    func hostRemoveRemoteStatusEntry(forKey key: String)

    /// Appends a remote sidebar log entry at `level` from `source`.
    func hostAppendRemoteSidebarLog(message: String, level: RemoteStatusLogLevel, source: String?)

    // MARK: - Error-dedup fingerprints (witnessed get/set)

    /// Dedup fingerprint for the last connection/suspend status notification.
    var hostRemoteLastErrorFingerprint: String? { get set }

    /// Dedup fingerprint for the last daemon-error log entry.
    var hostRemoteLastDaemonErrorFingerprint: String? { get set }

    /// Dedup fingerprint for the last port-conflict log entry.
    var hostRemoteLastPortConflictFingerprint: String? { get set }

    // MARK: - Slice-1 decision reads and notification routing

    /// Whether the workspace is preserving a proxy-only failure while a live SSH
    /// terminal is still usable. Faithful read of
    /// `Workspace.preservesProxyFailureWhileSSHTerminalIsAlive`.
    var hostPreservesProxyFailureWhileSSHTerminalIsAlive: Bool { get }

    /// Whether the workspace sidebar currently shows the proxy-only error.
    /// Faithful read of `Workspace.hasProxyOnlyRemoteSidebarError`.
    var hostHasProxyOnlyRemoteSidebarError: Bool { get }

    /// The notification cooldown key for `target`, or `nil`. Faithful read of
    /// `Workspace.remoteNotificationCooldownKey(target:)`.
    func hostRemoteNotificationCooldownKey(target: String) -> String?

    /// The remote notification cooldown interval (`Workspace.remoteNotificationCooldown`).
    var hostRemoteNotificationCooldown: TimeInterval { get }

    /// Posts a remote workspace notification (tab id and `nil` surface id are
    /// supplied app-side). Faithful forward to the workspace notification store's
    /// `addNotification(...)`.
    func hostAddRemoteNotification(
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String?,
        cooldownInterval: TimeInterval?
    )

    /// The resolved localized suspended-path copy, resolved app-side only when
    /// the suspended branch runs.
    var hostRemoteStatusStrings: RemoteStatusStrings { get }

    // MARK: - Browser-panel fan-out (app-target panel types)

    /// Pushes the current remote workspace status snapshot onto every browser
    /// panel. Faithful forward to `Workspace.applyBrowserRemoteWorkspaceStatusToPanels()`.
    func hostApplyBrowserRemoteWorkspaceStatusToPanels()

    /// Pushes `endpoint` onto every browser panel. Faithful equivalent of the
    /// `BrowserPanel.setRemoteProxyEndpoint(_:)` fan-out in
    /// `applyRemoteProxyEndpointUpdate(_:)`.
    func hostApplyRemoteProxyEndpointToBrowserPanels(_ endpoint: BrowserProxyEndpoint?)
}
