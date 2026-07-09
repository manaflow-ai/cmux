import CmuxCore
import CmuxRemoteWorkspace
import CmuxSidebar
import Foundation

/// `Workspace` is the live host for its `RemoteStatusCoordinator`. The
/// coordinator (in `CmuxRemoteWorkspace`) owns the publish-side remote-status
/// apply bodies; this witness reproduces the slice of live workspace state those
/// bodies read or push: the published remote-status stored state (each get/set
/// preserving the workspace's `didSet` Combine bridges), the per-surface
/// listening-port map, the sidebar status entries/log, the error-dedup
/// fingerprints, the slice-1 decision reads, the notification routing, the
/// resolved localized suspended copy, and the browser-panel fan-out (which
/// touches app-target panel types and so stays here).
///
/// This mirrors the sibling `Workspace+RemoteRelaySessionHosting`: the lifted
/// coordinator's live seam conformance lives in its own app-target file so
/// `Workspace.swift` drains the apply bodies instead of trading them for inline
/// seam glue. The coordinator is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
extension Workspace: RemoteStatusHosting {
    // MARK: - Published remote-status stored state

    var hostRemoteConnectionState: WorkspaceRemoteConnectionState {
        get { remoteConnectionState }
        set { remoteConnectionState = newValue }
    }

    var hostRemoteConnectionDetail: String? {
        get { remoteConnectionDetail }
        set { remoteConnectionDetail = newValue }
    }

    var hostRemoteDaemonStatus: WorkspaceRemoteDaemonStatus {
        get { remoteDaemonStatus }
        set { remoteDaemonStatus = newValue }
    }

    var hostRemoteProxyEndpoint: BrowserProxyEndpoint? {
        get { remoteProxyEndpoint }
        set { remoteProxyEndpoint = newValue }
    }

    var hostRemoteHeartbeatCount: Int {
        get { remoteHeartbeatCount }
        set { remoteHeartbeatCount = newValue }
    }

    var hostRemoteLastHeartbeatAt: Date? {
        get { remoteLastHeartbeatAt }
        set { remoteLastHeartbeatAt = newValue }
    }

    var hostRemoteDetectedPorts: [Int] {
        get { remoteDetectedPorts }
        set { remoteDetectedPorts = newValue }
    }

    var hostRemoteForwardedPorts: [Int] {
        get { remoteForwardedPorts }
        set { remoteForwardedPorts = newValue }
    }

    var hostRemotePortConflicts: [Int] {
        get { remotePortConflicts }
        set { remotePortConflicts = newValue }
    }

    var hostRemoteDetectedSurfaceIds: Set<UUID> {
        get { remoteDetectedSurfaceIds }
        set { remoteDetectedSurfaceIds = newValue }
    }

    // MARK: - Per-surface listening ports

    func hostRemoveSurfaceListeningPorts(forPanel panelId: UUID) {
        surfaceListeningPorts.removeValue(forKey: panelId)
    }

    func hostSetSurfaceListeningPorts(_ ports: [Int], forPanel panelId: UUID) {
        surfaceListeningPorts[panelId] = ports
    }

    func hostRecomputeListeningPorts() {
        recomputeListeningPorts()
    }

    // MARK: - Sidebar status entries and log

    var hostRemoteErrorStatusKey: String { Self.remoteErrorStatusKey }

    var hostRemotePortConflictStatusKey: String { Self.remotePortConflictStatusKey }

    func hostSetRemoteStatusEntry(forKey key: String, value: String, icon: String) {
        statusEntries[key] = SidebarStatusEntry(
            key: key,
            value: value,
            icon: icon,
            color: nil,
            timestamp: Date()
        )
    }

    func hostRemoveRemoteStatusEntry(forKey key: String) {
        statusEntries.removeValue(forKey: key)
    }

    func hostAppendRemoteSidebarLog(message: String, level: RemoteStatusLogLevel, source: String?) {
        let sidebarLevel: SidebarLogLevel
        switch level {
        case .warning: sidebarLevel = .warning
        case .error: sidebarLevel = .error
        }
        appendSidebarLog(message: message, level: sidebarLevel, source: source)
    }

    // MARK: - Error-dedup fingerprints

    var hostRemoteLastErrorFingerprint: String? {
        get { remoteLastErrorFingerprint }
        set { remoteLastErrorFingerprint = newValue }
    }

    var hostRemoteLastDaemonErrorFingerprint: String? {
        get { remoteLastDaemonErrorFingerprint }
        set { remoteLastDaemonErrorFingerprint = newValue }
    }

    var hostRemoteLastPortConflictFingerprint: String? {
        get { remoteLastPortConflictFingerprint }
        set { remoteLastPortConflictFingerprint = newValue }
    }

    // MARK: - Slice-1 decision reads and notification routing

    var hostPreservesProxyFailureWhileSSHTerminalIsAlive: Bool {
        preservesProxyFailureWhileSSHTerminalIsAlive
    }

    var hostHasProxyOnlyRemoteSidebarError: Bool {
        hasProxyOnlyRemoteSidebarError
    }

    func hostRemoteNotificationCooldownKey(target: String) -> String? {
        remoteNotificationCooldownKey(target: target)
    }

    var hostRemoteNotificationCooldown: TimeInterval {
        Self.remoteNotificationCooldown
    }

    func hostAddRemoteNotification(
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String?,
        cooldownInterval: TimeInterval?
    ) {
        hostEnvironment?.notificationStore?.addNotification(
            tabId: id,
            surfaceId: nil,
            title: title,
            subtitle: subtitle,
            body: body,
            cooldownKey: cooldownKey,
            cooldownInterval: cooldownInterval
        )
    }

    var hostRemoteStatusStrings: RemoteStatusStrings {
        RemoteStatusStrings.appLocalized
    }

    // MARK: - Browser-panel fan-out

    func hostApplyBrowserRemoteWorkspaceStatusToPanels() {
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func hostApplyRemoteProxyEndpointToBrowserPanels(_ endpoint: BrowserProxyEndpoint?) {
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
    }
}

extension RemoteStatusStrings {
    /// The remote-status suspended copy resolved against the app target's
    /// `Localizable.xcstrings`. `String(localized:)` must run in the app module,
    /// so the coordinator reads these already-resolved values through the host.
    static var appLocalized: RemoteStatusStrings {
        RemoteStatusStrings(
            suspendedStatusEntryFormat: String(
                localized: "remote.statusEntry.suspended",
                defaultValue: "SSH reconnect paused (%@): %@"
            ),
            suspendedNotificationTitle: String(
                localized: "remote.notification.suspendedTitle",
                defaultValue: "SSH Reconnect Paused"
            )
        )
    }
}
