import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import CmuxSidebar
import Foundation

/// `Workspace` is the live host for its `RemoteConnectionCoordinator`. The
/// coordinator (in `CmuxRemoteSession`) owns the remote *connection-lifecycle*
/// state and orchestration (configure / reconnect / disconnect / foreground-auth
/// readiness / the `applyRemote*Update` publish receivers / SSH control-master
/// cleanup / the wire-status payload); this witness reproduces the live
/// workspace state and side effects those bodies reach: sidebar status entries
/// and log lines, notifications, the per-surface listening-port and
/// remote-surface-tracking state (owned by `remoteSurfaceCoordinator`), the
/// browser-panel proxy/status fan-out, the listening-port recompute, the
/// initial-surface seeding, and the construction of the app-built
/// `RemoteSessionCoordinator`.
///
/// This mirrors the sibling `Workspace+RemoteSurfaceHosting` /
/// `Workspace+AgentHibernationHosting` witness pattern: the lifted coordinator's
/// live seam conformance lives in its own app-target file so `Workspace.swift`
/// drains the orchestration instead of trading it for inline seam glue. The
/// coordinator is held by `Workspace` and references this host weakly, so there
/// is no retain cycle.
extension Workspace: RemoteConnectionHosting {
    // MARK: - Identity / live reads
    //
    // `hostIsDetachingCloseTransaction`, `hostFocusedPanelId`, and
    // `hostWorkspaceID` are shared protocol requirements already witnessed in
    // `Workspace+RemoteSurfaceHosting.swift`; a single impl satisfies both
    // protocols, so they are not re-declared here.

    var hostRemoteDisplayTarget: String? { remoteDisplayTarget }

    var hostHasPendingDetachedSurfaces: Bool { pendingDetachedSurfacesIsEmpty == false }

    var hostHasProxyOnlyRemoteSidebarError: Bool { hasProxyOnlyRemoteSidebarError }

    var hostRemoteNotificationCooldown: TimeInterval { Self.remoteNotificationCooldown }

    var hostHasNoPanels: Bool { panels.isEmpty }

    var hostHasBrowserPanels: Bool {
        panels.values.contains { $0 is BrowserPanel }
    }

    var hostHasNoActiveRemoteTerminalSurfaces: Bool {
        remoteSurfaceCoordinator.state.activeRemoteTerminalSurfaceIds.isEmpty
    }

    // MARK: - Surface-tracking bridge

    func hostPanelIsTerminal(_ panelId: UUID) -> Bool {
        panels[panelId] is TerminalPanel
    }

    func hostTrackRemoteTerminalSurface(_ panelId: UUID) {
        trackRemoteTerminalSurface(panelId)
    }

    func hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
    }

    func hostResetRemoteSurfaceStateForNewConfiguration(
        previous: WorkspaceRemoteConfiguration?,
        next: WorkspaceRemoteConfiguration
    ) {
        guard let previous,
              previous != next,
              !previous.hasSamePersistentPTYIdentity(as: next) else {
            return
        }
        remoteSurfaceCoordinator.state.remotePTYSessionIDsByPanelId.removeAll()
        remoteSurfaceCoordinator.state.endedPersistentRemotePTYAttachSurfaceIds.removeAll()
        remoteSurfaceCoordinator.clearRemoteRelayIDAliases()
    }

    func hostClearRemoteSurfaceStateForDisconnect(clearConfiguration: Bool) {
        remoteSurfaceCoordinator.state.activeRemoteTerminalSurfaceIds.removeAll()
        remoteSurfaceCoordinator.state.endedPersistentRemotePTYAttachSurfaceIds.removeAll()
        remoteSurfaceCoordinator.state.pendingRemoteSurfaceTTYName = nil
        remoteSurfaceCoordinator.state.pendingRemoteSurfaceTTYSurfaceId = nil
        remoteSurfaceCoordinator.state.pendingRemoteSurfacePortKickReason = nil
        remoteSurfaceCoordinator.state.pendingRemoteSurfacePortKickSurfaceId = nil
        if clearConfiguration {
            remoteSurfaceCoordinator.state.remotePTYSessionIDsByPanelId.removeAll()
            remoteSurfaceCoordinator.state.endedPersistentRemotePTYAttachSurfaceIds.removeAll()
            remoteSurfaceCoordinator.clearRemoteRelayIDAliases()
        }
    }

    var hostSkipControlMasterCleanupAfterDetachedRemoteTransfer: Bool {
        get { remoteSurfaceCoordinator.state.skipControlMasterCleanupAfterDetachedRemoteTransfer }
        set { remoteSurfaceCoordinator.state.skipControlMasterCleanupAfterDetachedRemoteTransfer = newValue }
    }

    func hostSyncRemotePortScanTTYs() {
        remoteSurfaceCoordinator.syncRemotePortScanTTYs()
    }

    func hostSyncRemoteRelayIDAliasesToController() {
        remoteSurfaceCoordinator.syncRemoteRelayIDAliasesToController()
    }

    var hostRemoteDetectedSurfaceIds: Set<UUID> {
        get { remoteSurfaceCoordinator.state.remoteDetectedSurfaceIds }
        set { remoteSurfaceCoordinator.state.remoteDetectedSurfaceIds = newValue }
    }

    // MARK: - Listening-port projection

    func hostRemoveSurfaceListeningPorts(_ panelId: UUID) {
        surfaceListeningPorts.removeValue(forKey: panelId)
    }

    func hostSetSurfaceListeningPorts(_ ports: [Int], for panelId: UUID) {
        surfaceListeningPorts[panelId] = ports
    }

    func hostRecomputeListeningPorts() {
        recomputeListeningPorts()
    }

    // MARK: - Sidebar status / log / notifications

    var hostRemoteErrorStatusKey: String { Self.remoteErrorStatusKey }

    var hostRemotePortConflictStatusKey: String { Self.remotePortConflictStatusKey }

    func hostSetStatusEntry(_ entry: SidebarStatusEntry, forKey key: String) {
        statusEntries[key] = entry
    }

    func hostRemoveStatusEntry(forKey key: String) {
        statusEntries.removeValue(forKey: key)
    }

    func hostStatusEntryValue(forKey key: String) -> String? {
        statusEntries[key]?.value
    }

    func hostAppendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        sidebarMetadata.appendLogEntry(message: message, level: level, source: source)
    }

    func hostAddRemoteNotification(
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String?,
        cooldownInterval: TimeInterval
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

    // MARK: - Browser fan-out

    func hostApplyRemoteProxyEndpointToBrowserPanels(_ endpoint: BrowserProxyEndpoint?) {
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
    }

    func hostApplyBrowserRemoteWorkspaceStatusToPanels() {
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    // MARK: - Session-coordinator construction

    func hostMakeRemoteSessionController(
        configuration: WorkspaceRemoteConfiguration,
        controllerID: UUID
    ) -> RemoteSessionCoordinator {
        var processRunner: any RemoteSessionProcessRunning = RemoteSessionProcessRunner()
#if DEBUG
        if let override = remoteSessionProcessRunnerOverrideForTesting {
            processRunner = override
        }
#endif
        return RemoteSessionCoordinator(
            host: WorkspaceRemoteSessionHostAdapter(workspace: self, controllerID: controllerID),
            configuration: configuration,
            proxyBroker: TerminalController.shared.remoteProxyBroker,
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            processRunner: processRunner,
            reachabilityProbe: RemoteHostReachabilityProbe(),
            relayCommandRewriter: WorkspaceRemoteRelayCommandRewriter(),
            buildInfo: WorkspaceRemoteSessionBuildInfo(),
            daemonStrings: RemoteDaemonStrings.appLocalized,
            strings: RemoteSessionStrings.appLocalized
        )
    }

    func hostRemotePortScanningEnabled() -> Bool {
        Self.remotePortScanningEnabledFromSettings()
    }

    func hostNotifyRemotePTYControllerAvailabilityChanged() {
        TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged()
    }
}
