public import CmuxCore
public import CmuxSidebar
public import Foundation

/// The live-workspace seam the ``RemoteConnectionCoordinator`` reaches back
/// through for the side effects it cannot own in the package: sidebar status
/// entries and log lines, notifications, the per-surface listening-port and
/// remote-surface-tracking state (owned by ``RemoteSurfaceCoordinator``), the
/// browser-panel proxy/status fan-out, the listening-port recompute, the
/// initial-surface seeding, and the construction of the app-built
/// ``RemoteSessionCoordinator`` (which carries app-target collaborators such as
/// the proxy broker, process runner, and publish adapter).
///
/// This mirrors the sibling ``RemoteSurfaceHosting`` witness pattern: the lifted
/// coordinator's live seam conformance lives in its own app-target file
/// (`Workspace+RemoteConnectionHosting.swift`) so `Workspace.swift` drains the
/// orchestration instead of trading it for inline seam glue. The coordinator is
/// held by `Workspace` and references the host weakly, so there is no retain
/// cycle.
///
/// Every member runs on the main actor (the coordinator is `@MainActor`,
/// matching the legacy `Workspace`-method isolation exactly).
@MainActor
public protocol RemoteConnectionHosting: AnyObject {
    // MARK: - Identity / live reads

    /// The display target for the live remote configuration, or `nil`.
    var hostRemoteDisplayTarget: String? { get }
    /// Whether a detaching-close transaction is in flight (suppresses cleanup).
    var hostIsDetachingCloseTransaction: Bool { get }
    /// Whether there are pending detached surfaces (suppresses cleanup).
    var hostHasPendingDetachedSurfaces: Bool { get }
    /// Whether the live sidebar carries a proxy-only remote error entry.
    var hostHasProxyOnlyRemoteSidebarError: Bool { get }
    /// The remote-notification cooldown interval.
    var hostRemoteNotificationCooldown: TimeInterval { get }
    /// Whether the workspace currently has no panels (a workspace that became
    /// local after its last remote terminal closed).
    var hostHasNoPanels: Bool { get }
    /// Whether the workspace currently hosts at least one browser panel (a
    /// remote workspace with a live browser panel must not be demoted to local).
    var hostHasBrowserPanels: Bool { get }
    /// Whether there are no active remote-terminal surfaces left (the SSH-session
    /// demotion chain gate; the surface set is owned by the surface coordinator).
    var hostHasNoActiveRemoteTerminalSurfaces: Bool { get }

    // MARK: - Surface-tracking bridge (RemoteSurfaceCoordinator state)

    /// Whether `panelId` currently hosts a terminal panel.
    func hostPanelIsTerminal(_ panelId: UUID) -> Bool
    /// Tracks `panelId` as an active remote-terminal surface.
    func hostTrackRemoteTerminalSurface(_ panelId: UUID)
    /// Seeds the initial remote-terminal session for a new configuration.
    func hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration)
    /// Whether two configurations share the same persistent-PTY identity guard
    /// reset must be skipped for; mirrors the surface-state reset in configure.
    func hostResetRemoteSurfaceStateForNewConfiguration(
        previous: WorkspaceRemoteConfiguration?,
        next: WorkspaceRemoteConfiguration
    )
    /// Clears the active/ended/pending remote-terminal surface bookkeeping on
    /// disconnect.
    func hostClearRemoteSurfaceStateForDisconnect(clearConfiguration: Bool)
    /// Whether the disconnect path should skip SSH control-master cleanup
    /// because a detached remote transfer is in progress.
    var hostSkipControlMasterCleanupAfterDetachedRemoteTransfer: Bool { get set }
    /// Re-syncs the remote port-scan TTYs into the active session coordinator.
    func hostSyncRemotePortScanTTYs()
    /// Re-syncs the remote relay id aliases into the active session coordinator.
    func hostSyncRemoteRelayIDAliasesToController()
    /// The set of remote-detected surface ids whose listening ports are tracked.
    var hostRemoteDetectedSurfaceIds: Set<UUID> { get set }

    // MARK: - Listening-port projection

    /// Removes the tracked listening ports for a surface.
    func hostRemoveSurfaceListeningPorts(_ panelId: UUID)
    /// Sets the tracked listening ports for a surface.
    func hostSetSurfaceListeningPorts(_ ports: [Int], for panelId: UUID)
    /// Recomputes the fused workspace listening-port projection.
    func hostRecomputeListeningPorts()

    // MARK: - Sidebar status / log / notifications

    /// The sidebar status key for the remote connection error entry.
    var hostRemoteErrorStatusKey: String { get }
    /// The sidebar status key for the remote port-conflict entry.
    var hostRemotePortConflictStatusKey: String { get }
    /// Sets a sidebar status entry.
    func hostSetStatusEntry(_ entry: SidebarStatusEntry, forKey key: String)
    /// Removes a sidebar status entry.
    func hostRemoveStatusEntry(forKey key: String)
    /// The current value of a sidebar status entry, if present.
    func hostStatusEntryValue(forKey key: String) -> String?
    /// Appends a sidebar log line.
    func hostAppendSidebarLog(message: String, level: SidebarLogLevel, source: String?)
    /// Posts a remote-error notification with cooldown.
    func hostAddRemoteNotification(
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String?,
        cooldownInterval: TimeInterval
    )

    // MARK: - Browser fan-out

    /// Applies the remote proxy endpoint to every browser panel.
    func hostApplyRemoteProxyEndpointToBrowserPanels(_ endpoint: BrowserProxyEndpoint?)
    /// Re-applies the remote-workspace status snapshot to every browser panel.
    func hostApplyBrowserRemoteWorkspaceStatusToPanels()

    // MARK: - Session-coordinator construction

    /// Builds the app-target ``RemoteSessionCoordinator`` for a connection
    /// attempt (carrying the proxy broker, process runner, reachability probe,
    /// relay rewriter, build info, localized strings, and the publish adapter
    /// bound to `controllerID`).
    func hostMakeRemoteSessionController(
        configuration: WorkspaceRemoteConfiguration,
        controllerID: UUID
    ) -> RemoteSessionCoordinator
    /// Whether the host's remote port-scan loop may run (sidebar settings).
    func hostRemotePortScanningEnabled() -> Bool
    /// Notifies the host that remote-PTY controller availability changed
    /// (fired in the `defer` of configure/disconnect).
    func hostNotifyRemotePTYControllerAvailabilityChanged()
}
