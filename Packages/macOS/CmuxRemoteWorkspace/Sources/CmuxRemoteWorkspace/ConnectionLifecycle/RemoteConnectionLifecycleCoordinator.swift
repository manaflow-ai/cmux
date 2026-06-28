public import Foundation

public import CmuxCore

/// Per-workspace owner of the top-level remote connection-lifecycle orchestration:
/// the bodies that configure a remote connection (resetting the full published
/// remote-status surface and constructing the live session), reconnect it, consume
/// a foreground-authentication readiness signal, disconnect it, and demote the
/// workspace to local when its last panel closes.
///
/// This lifts the orchestration bodies of the legacy `Workspace` methods
/// `configureRemoteConnection(_:autoConnect:)`,
/// `reconnectRemoteConnection(surfaceId:)`,
/// `notifyRemoteForegroundAuthenticationReady(token:)`,
/// `disconnectRemoteConnection(clearConfiguration:disconnectedDetail:)`, and
/// `clearRemoteConfigurationIfWorkspaceBecameLocal()`. The workspace keeps thin
/// forwarders for the externally-called methods so the session-restore init, the
/// control-socket / web-API close, the `RemoteSurfaceHosting` detach/transfer
/// path, the agent-fork launch, and the slice-4
/// `disconnectRemoteConnectionAfterTerminalExit()` callers still resolve.
///
/// The live published state, the single live `RemoteSessionCoordinator`, and the
/// localized strings stay app-side and are read/written/forwarded through
/// ``RemoteConnectionLifecycleHosting``. The session construction in particular
/// stays app-side behind ``RemoteConnectionLifecycleHosting/hostMakeAndStartRemoteSession(configuration:controllerID:)``
/// because its dependency graph names `TerminalController.shared` and other
/// symbols that cannot move down a module boundary.
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every lifted body was a
/// plain method on the `@MainActor` `Workspace` class, so every read, write, and
/// forward already ran on the main actor. The host reference is weak (the
/// workspace owns the coordinator), so there is no retain cycle.
@MainActor
public final class RemoteConnectionLifecycleCoordinator<Host: RemoteConnectionLifecycleHosting> {
    private weak var host: Host?

    /// Creates a coordinator. Call ``attach(host:)`` at the composition point
    /// before any connection-lifecycle orchestration runs.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    /// Normalizes a foreground-authentication token (trims, drops empties).
    /// Faithful lift of the legacy `Workspace.normalizedForegroundAuthToken(_:)`.
    private static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        RemoteForegroundAuthToken().normalized(token)
    }

    /// Configures (and, when appropriate, auto-connects) the workspace's remote
    /// connection, resetting the full published remote-status surface and
    /// constructing the live session. Faithful lift of
    /// `Workspace.configureRemoteConnection(_:autoConnect:)`.
    public func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        guard let host else { return }
        defer { host.hostNotifyRemotePTYControllerAvailabilityChanged() }
        let previousConfiguration = host.hostRemoteConfiguration
        host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer = false
        host.hostPendingRemoteDisconnectReplacement = nil
        let remoteDisconnectPlaceholderPanelIdsToClear = host.hostRemoteDisconnectPlaceholderPanelIds
        if let previousConfiguration,
           previousConfiguration != configuration,
           !previousConfiguration.hasSamePersistentPTYIdentity(as: configuration) {
            host.hostRemoveAllRemotePTYSessionIDs()
            host.hostClearEndedPersistentRemotePTYAttachSurfaceIds()
            host.hostClearRemoteRelayIDAliases()
        }
        host.hostRemoteConfiguration = configuration
        host.hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        host.hostSubtractRemoteDisconnectPlaceholderPanelIds(remoteDisconnectPlaceholderPanelIdsToClear)
        host.hostClearRemoteDetectedSurfacePorts()
        host.hostRemoteDetectedPorts = []
        host.hostRemoteForwardedPorts = []
        host.hostRemotePortConflicts = []
        host.hostRemoteProxyEndpoint = nil
        host.hostRemoteHeartbeatCount = 0
        host.hostRemoteLastHeartbeatAt = nil
        host.hostRemoteConnectionDetail = nil
        host.hostRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        host.hostRemoveRemoteStatusEntry(forKey: host.hostRemoteErrorStatusKey)
        host.hostRemoveRemoteStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
        host.hostRemoteLastErrorFingerprint = nil
        host.hostRemoteLastDaemonErrorFingerprint = nil
        host.hostRemoteLastPortConflictFingerprint = nil
        host.hostRecomputeListeningPorts()

        host.hostStopRemoteSession()
        host.hostApplyRemoteProxyEndpointUpdate(nil)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()

        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == host.hostPendingRemoteForegroundAuthToken)
        host.hostPendingRemoteForegroundAuthToken = nil
        if configuration.transport == .websocket,
           configuration.daemonWebSocketEndpoint == nil {
            host.hostRemoteConnectionState = .connected
            host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
            return
        }
        guard shouldAutoConnect else {
            host.hostRemoteConnectionState = .disconnected
            host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        host.hostRemoteConnectionState = .connecting
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        host.hostMakeAndStartRemoteSession(configuration: configuration, controllerID: controllerID)
    }

    /// Reconnects the workspace's remote connection, re-tracking a placeholder
    /// terminal surface when given. Faithful lift of
    /// `Workspace.reconnectRemoteConnection(surfaceId:)`.
    public func reconnectRemoteConnection(surfaceId: UUID? = nil) {
        guard let host else { return }
        guard let configuration = host.hostRemoteConfiguration else { return }
        let reconnectingPlaceholderSurfaceId = surfaceId.flatMap { candidate -> UUID? in
            guard host.hostRemoteDisconnectPlaceholderPanelIds.contains(candidate),
                  host.hostIsTerminalPanel(candidate) else {
                return nil
            }
            return candidate
        }
        if let reconnectingPlaceholderSurfaceId {
            host.hostRemoveRemoteDisconnectPlaceholderPanelId(reconnectingPlaceholderSurfaceId)
            host.hostTrackRemoteTerminalSurface(reconnectingPlaceholderSurfaceId)
        }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    /// Consumes a remote foreground-authentication readiness signal, reconnecting
    /// when the token matches the current configuration and the workspace is
    /// disconnected. Faithful lift of
    /// `Workspace.notifyRemoteForegroundAuthenticationReady(token:)`.
    public func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let host else { return }
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration = host.hostRemoteConfiguration else {
            host.hostPendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        host.hostPendingRemoteForegroundAuthToken = nil
        guard host.hostRemoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    /// Disconnects the workspace's remote connection, resetting the full published
    /// remote-status surface and optionally clearing the configuration. Faithful
    /// lift of `Workspace.disconnectRemoteConnection(clearConfiguration:disconnectedDetail:)`.
    public func disconnectRemoteConnection(clearConfiguration: Bool = false, disconnectedDetail: String? = nil) {
        guard let host else { return }
        defer { host.hostNotifyRemotePTYControllerAvailabilityChanged() }
        let shouldCleanupControlMaster =
            clearConfiguration
            && !host.hostIsDetachingCloseTransaction
            && host.hostPendingDetachedSurfacesIsEmpty
            && !host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? host.hostRemoteConfiguration : nil
        host.hostStopRemoteSession()
        host.hostPendingRemoteForegroundAuthToken = nil
        host.hostClearActiveRemoteTerminalSurfaceIds()
        host.hostClearEndedPersistentRemotePTYAttachSurfaceIds()
        host.hostResetActiveRemoteTerminalSessionCount()
        host.hostPendingRemoteSurfaceTTYName = nil
        host.hostPendingRemoteSurfaceTTYSurfaceId = nil
        host.hostPendingRemoteSurfacePortKickReason = nil
        host.hostPendingRemoteSurfacePortKickSurfaceId = nil
        host.hostClearRemoteDetectedSurfacePorts()
        host.hostRemoteDetectedPorts = []
        host.hostRemoteForwardedPorts = []
        host.hostRemotePortConflicts = []
        host.hostRemoteProxyEndpoint = nil
        host.hostRemoteHeartbeatCount = 0
        host.hostRemoteLastHeartbeatAt = nil
        host.hostRemoteConnectionState = .disconnected
        host.hostRemoteConnectionDetail = disconnectedDetail
        host.hostRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        host.hostRemoveRemoteStatusEntry(forKey: host.hostRemoteErrorStatusKey)
        host.hostRemoveRemoteStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
        host.hostRemoteLastErrorFingerprint = nil
        host.hostRemoteLastDaemonErrorFingerprint = nil
        host.hostRemoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            host.hostRemoveAllRemotePTYSessionIDs()
            host.hostClearEndedPersistentRemotePTYAttachSurfaceIds()
            host.hostClearRemoteRelayIDAliases()
            host.hostRemoteConfiguration = nil
            host.hostPendingRemoteDisconnectReplacement = nil
            host.hostClearRemoteDisconnectPlaceholderPanelIds()
            host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        host.hostApplyRemoteProxyEndpointUpdate(nil)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        host.hostRecomputeListeningPorts()
        if let configurationForCleanup {
            host.hostRequestSSHControlMasterCleanup(configuration: configurationForCleanup)
        }
    }

    /// Demotes the workspace to local (disconnecting and clearing configuration)
    /// once its last panel closes and nothing keeps the remote session alive.
    /// Faithful lift of `Workspace.clearRemoteConfigurationIfWorkspaceBecameLocal()`.
    public func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard let host else { return }
        guard !host.hostIsDetachingCloseTransaction, host.hostPanelsIsEmpty, host.hostRemoteConfiguration != nil else { return }
        guard host.hostPendingRemoteDisconnectReplacement == nil else { return }
        if host.hostRemoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        disconnectRemoteConnection(clearConfiguration: true)
    }
}
