import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteSession
import CmuxRemoteWorkspace
import Foundation

/// `Workspace` is the live host for its `RemoteConnectionLifecycleCoordinator`.
/// The coordinator (in `CmuxRemoteWorkspace`) owns the top-level connection
/// lifecycle orchestration bodies (configure/reconnect/notify-foreground/
/// disconnect/clear-on-local); this witness reproduces the slice of live workspace
/// state those bodies read, reset, or forward that the sibling seams do not already
/// expose.
///
/// Most of the published-state reset surface, the detach/cleanup flags, and the
/// pending TTY / port-kick fields are already witnessed by the sibling
/// `Workspace+RemoteStatusHosting`, `Workspace+RemoteSurfaceHosting`,
/// `Workspace+RemoteSurfaceTTYHosting`, and `Workspace+RemoteTerminalTrackingHosting`
/// extensions; `Workspace` conforms to all of those seams, so those single
/// implementations satisfy this seam too and are not repeated here. This file adds
/// only the members unique to the lifecycle slice: the pending foreground-auth
/// token get/set, the remote-disconnect placeholder set operations, the
/// tracked-set/relay clears, the session-count reset, the panel-map probes, the
/// sibling-tracking-coordinator forwards, and the single live
/// `RemoteSessionCoordinator` construction/teardown plus the remote-PTY
/// availability notification. The session construction stays here because its
/// dependency graph names `TerminalController.shared`,
/// `WorkspaceRemoteSessionHostAdapter`, `RemoteDaemonManifestRepository`, the
/// `*.appLocalized` localized strings, and the DEBUG test-runner override, none of
/// which can move down a module boundary.
///
/// The coordinator is held by `Workspace` and references this host weakly, so
/// there is no retain cycle.
extension Workspace: RemoteConnectionLifecycleHosting {
    // `PortKickReason` (the protocol's associated type) resolves to
    // `PortScanKickReason` through the `typealias` the sibling
    // `Workspace+RemoteSurfaceTTYHosting` witness already declares on `Workspace`;
    // a second declaration here would redeclare that member.

    // MARK: - Foreground auth token

    var hostPendingRemoteForegroundAuthToken: String? {
        get { pendingRemoteForegroundAuthToken }
        set { pendingRemoteForegroundAuthToken = newValue }
    }

    // MARK: - Remote-disconnect placeholder panel ids

    var hostRemoteDisconnectPlaceholderPanelIds: Set<UUID> {
        remoteDisconnectPlaceholderPanelIds
    }

    func hostSubtractRemoteDisconnectPlaceholderPanelIds(_ ids: Set<UUID>) {
        remoteDisconnectPlaceholderPanelIds.subtract(ids)
    }

    func hostRemoveRemoteDisconnectPlaceholderPanelId(_ id: UUID) {
        remoteDisconnectPlaceholderPanelIds.remove(id)
    }

    func hostClearRemoteDisconnectPlaceholderPanelIds() {
        remoteDisconnectPlaceholderPanelIds.removeAll()
    }

    // MARK: - Tracked-set / relay clears

    func hostClearActiveRemoteTerminalSurfaceIds() {
        activeRemoteTerminalSurfaceIds.removeAll()
    }

    func hostClearEndedPersistentRemotePTYAttachSurfaceIds() {
        endedPersistentRemotePTYAttachSurfaceIds.removeAll()
    }

    func hostResetActiveRemoteTerminalSessionCount() {
        resetActiveRemoteTerminalSessionCount()
    }

    func hostRemoveAllRemotePTYSessionIDs() {
        remoteRelaySession.removeAllRemotePTYSessionIDs()
    }

    func hostClearRemoteRelayIDAliases() {
        remoteRelaySession.clearRemoteRelayIDAliases()
    }

    // MARK: - Status fan-out forwards

    func hostApplyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        applyRemoteProxyEndpointUpdate(endpoint)
    }

    func hostClearRemoteDetectedSurfacePorts() {
        remoteStatus.clearRemoteDetectedSurfacePorts()
    }

    // MARK: - Panel probes

    func hostIsTerminalPanel(_ panelId: UUID) -> Bool {
        panels[panelId] is TerminalPanel
    }

    var hostPanelsIsEmpty: Bool {
        panels.isEmpty
    }

    // MARK: - Sibling-coordinator forwards

    func hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        remoteTerminalTracking.seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
    }

    func hostTrackRemoteTerminalSurface(_ panelId: UUID) {
        trackRemoteTerminalSurface(panelId)
    }

    // MARK: - Live session construction (app-side)

    func hostMakeAndStartRemoteSession(configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        var processRunner: any RemoteSessionProcessRunning = RemoteSessionProcessRunner()
#if DEBUG
        if let override = remoteSessionProcessRunnerOverrideForTesting {
            processRunner = override
        }
#endif
        let controller = RemoteSessionCoordinator(
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
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.updateRemotePortScanningEnabled(Self.remotePortScanningEnabledFromSettings())
        syncRemotePortScanTTYs()
        remoteRelaySession.syncRemoteRelayIDAliasesToController()
        controller.start()
    }

    func hostStopRemoteSession() {
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
    }

    func hostNotifyRemotePTYControllerAvailabilityChanged() {
        TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged()
    }
}
