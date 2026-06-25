public import CmuxCore
internal import CmuxSidebar
public import Foundation

/// Per-workspace orchestrator for the remote *connection lifecycle*: configure,
/// reconnect, disconnect, foreground-auth readiness, the publish-side state
/// receivers (`applyRemote*Update`), the SSH control-master cleanup, the
/// disconnect-replacement bookkeeping, and the wire-status payload.
///
/// This is the connection-lifecycle counterpart to ``RemoteSurfaceCoordinator``
/// (remote *surface* commands) and ``RemoteSessionCoordinator`` (the SSH/daemon
/// transport). It owns the connection-lifecycle ``RemoteConnectionState`` and
/// reaches the small slice of live workspace state it needs (sidebar status,
/// notifications, browser fan-out, surface tracking, session-controller
/// construction) through ``RemoteConnectionHosting``.
///
/// Faithful lift of the `Workspace` remote-connection methods; the orchestration
/// logic, dedupe fingerprints, status strings, and side-effect order are pinned
/// legacy behavior.
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every method lifted here
/// was a plain method on the `@MainActor` `Workspace` class, so every read/write
/// of live state and every publish receiver already ran on the main actor. The
/// SSH/daemon work that runs off-main lives in ``RemoteSessionCoordinator``, not
/// here. The host reference is weak (the workspace owns the coordinator), so
/// there is no retain cycle.
@MainActor
public final class RemoteConnectionCoordinator<Host: RemoteConnectionHosting> {
    // `internal` (not `private`) so the per-concern extension files can reach
    // the live host and state.
    weak var host: Host?

    /// The connection-lifecycle state this coordinator owns. `Workspace`
    /// forwards each former stored property to a member of this model.
    public let state = RemoteConnectionState()

    /// App-resolved localized strings (the package never localizes). Seeded
    /// with empty defaults until ``attach(host:strings:)`` injects the
    /// app-bundle values; the lifecycle methods only run after attach.
    var strings = RemoteConnectionStrings(
        terminalDisconnectedDetail: "",
        suspendedStatusEntryFormat: "",
        suspendedNotificationTitle: "",
        disconnectBannerSessionEndedFormat: "",
        disconnectBannerReconnectHint: "",
        disconnectBannerReconnectUnavailableHint: ""
    )

    /// Creates a connection coordinator. Call ``attach(host:strings:)`` at the
    /// composition point before any lifecycle method runs.
    public init() {}

    /// Binds the live workspace host and the app-localized strings. Call once,
    /// before any configure/reconnect/disconnect or publish receiver runs.
    public func attach(host: Host, strings: RemoteConnectionStrings) {
        self.host = host
        self.strings = strings
    }

    // MARK: - Wire status payload

    /// The wire-protocol status payload for `workspace.status` / remote control
    /// commands.
    public func remoteStatusPayload() -> [String: Any] {
        RemoteStatusSnapshot(
            configuration: state.remoteConfiguration,
            connectionState: state.remoteConnectionState,
            activeTerminalSessionCount: state.activeRemoteTerminalSessionCount,
            daemonStatus: state.remoteDaemonStatus,
            detectedPorts: state.remoteDetectedPorts,
            forwardedPorts: state.remoteForwardedPorts,
            portConflicts: state.remotePortConflicts,
            connectionDetail: state.remoteConnectionDetail,
            heartbeatCount: state.remoteHeartbeatCount,
            lastHeartbeatAt: state.remoteLastHeartbeatAt,
            proxyEndpoint: state.remoteProxyEndpoint,
            hasProxyOnlySidebarError: host?.hostHasProxyOnlyRemoteSidebarError ?? false
        ).payload()
    }

    // MARK: - Configure / reconnect

    /// Configures (and optionally auto-connects) a remote connection.
    public func configureRemoteConnection(
        _ configuration: WorkspaceRemoteConfiguration,
        autoConnect: Bool = true
    ) {
        guard let host else { return }
        defer { host.hostNotifyRemotePTYControllerAvailabilityChanged() }
        let previousConfiguration = state.remoteConfiguration
        host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer = false
        state.pendingRemoteDisconnectReplacement = nil
        let remoteDisconnectPlaceholderPanelIdsToClear = state.remoteDisconnectPlaceholderPanelIds
        host.hostResetRemoteSurfaceStateForNewConfiguration(
            previous: previousConfiguration,
            next: configuration
        )
        state.remoteConfiguration = configuration
        host.hostSeedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        state.remoteDisconnectPlaceholderPanelIds.subtract(remoteDisconnectPlaceholderPanelIdsToClear)
        clearRemoteDetectedSurfacePorts()
        state.remoteDetectedPorts = []
        state.remoteForwardedPorts = []
        state.remotePortConflicts = []
        state.remoteProxyEndpoint = nil
        state.remoteHeartbeatCount = 0
        state.remoteLastHeartbeatAt = nil
        state.remoteConnectionDetail = nil
        state.remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        host.hostRemoveStatusEntry(forKey: host.hostRemoteErrorStatusKey)
        host.hostRemoveStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
        state.remoteLastErrorFingerprint = nil
        state.remoteLastDaemonErrorFingerprint = nil
        state.remoteLastPortConflictFingerprint = nil
        host.hostRecomputeListeningPorts()

        let previousController = state.remoteSessionController
        state.activeRemoteSessionControllerID = nil
        state.remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()

        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == state.pendingRemoteForegroundAuthToken)
        state.pendingRemoteForegroundAuthToken = nil
        if configuration.transport == .websocket,
           configuration.daemonWebSocketEndpoint == nil {
            state.remoteConnectionState = .connected
            host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
            return
        }
        guard shouldAutoConnect else {
            state.remoteConnectionState = .disconnected
            host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        state.remoteConnectionState = .connecting
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = host.hostMakeRemoteSessionController(
            configuration: configuration,
            controllerID: controllerID
        )
        state.activeRemoteSessionControllerID = controllerID
        state.remoteSessionController = controller
        controller.updateRemotePortScanningEnabled(host.hostRemotePortScanningEnabled())
        host.hostSyncRemotePortScanTTYs()
        host.hostSyncRemoteRelayIDAliasesToController()
        controller.start()
    }

    /// Reconnects the current remote configuration, optionally promoting a
    /// disconnect-placeholder surface back to a tracked remote surface.
    public func reconnectRemoteConnection(surfaceId: UUID? = nil) {
        guard let host else { return }
        guard let configuration = state.remoteConfiguration else { return }
        let reconnectingPlaceholderSurfaceId = surfaceId.flatMap { candidate -> UUID? in
            guard state.remoteDisconnectPlaceholderPanelIds.contains(candidate),
                  host.hostPanelIsTerminal(candidate) else {
                return nil
            }
            return candidate
        }
        if let reconnectingPlaceholderSurfaceId {
            state.remoteDisconnectPlaceholderPanelIds.remove(reconnectingPlaceholderSurfaceId)
            host.hostTrackRemoteTerminalSurface(reconnectingPlaceholderSurfaceId)
        }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Records (or completes) a deferred foreground-authentication readiness
    /// signal: reconnects if the live configuration's token matches.
    public func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration = state.remoteConfiguration else {
            state.pendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        state.pendingRemoteForegroundAuthToken = nil
        guard state.remoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    // MARK: - Disconnect

    /// Disconnects the remote connection, optionally clearing the configuration
    /// (full teardown) and surfacing a disconnected-detail string.
    public func disconnectRemoteConnection(
        clearConfiguration: Bool = false,
        disconnectedDetail: String? = nil
    ) {
        guard let host else { return }
        defer { host.hostNotifyRemotePTYControllerAvailabilityChanged() }
        let shouldCleanupControlMaster =
            clearConfiguration
            && !host.hostIsDetachingCloseTransaction
            && !host.hostHasPendingDetachedSurfaces
            && !host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? state.remoteConfiguration : nil
        let previousController = state.remoteSessionController
        state.activeRemoteSessionControllerID = nil
        state.remoteSessionController = nil
        previousController?.stop()
        state.pendingRemoteForegroundAuthToken = nil
        host.hostClearRemoteSurfaceStateForDisconnect(clearConfiguration: clearConfiguration)
        state.activeRemoteTerminalSessionCount = 0
        clearRemoteDetectedSurfacePorts()
        state.remoteDetectedPorts = []
        state.remoteForwardedPorts = []
        state.remotePortConflicts = []
        state.remoteProxyEndpoint = nil
        state.remoteHeartbeatCount = 0
        state.remoteLastHeartbeatAt = nil
        state.remoteConnectionState = .disconnected
        state.remoteConnectionDetail = disconnectedDetail
        state.remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        host.hostRemoveStatusEntry(forKey: host.hostRemoteErrorStatusKey)
        host.hostRemoveStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
        state.remoteLastErrorFingerprint = nil
        state.remoteLastDaemonErrorFingerprint = nil
        state.remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            state.remoteConfiguration = nil
            state.pendingRemoteDisconnectReplacement = nil
            state.remoteDisconnectPlaceholderPanelIds.removeAll()
            host.hostSkipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        applyRemoteProxyEndpointUpdate(nil)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        host.hostRecomputeListeningPorts()
        if let configurationForCleanup {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: configurationForCleanup)
        }
    }

    /// Full teardown: disconnect and clear the configuration.
    public func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    /// Stops the active session coordinator on workspace deinit. The workspace's
    /// `isolated deinit` delegates here so the connection cluster owns the
    /// session-controller stop()/clear it owns the storage for, instead of the
    /// god reaching into the moved state. Side-effect-free beyond the controller
    /// stop (no host required; the host is already torn down at deinit time).
    public func teardownOnWorkspaceDeinit() {
        let previousController = state.remoteSessionController
        state.activeRemoteSessionControllerID = nil
        state.remoteSessionController = nil
        previousController?.stop()
    }

    /// Disconnect after a remote terminal session exited (keeps the config).
    public func disconnectRemoteConnectionAfterTerminalExit() {
        disconnectRemoteConnection(
            clearConfiguration: false,
            disconnectedDetail: strings.terminalDisconnectedDetail
        )
    }

    /// Remembers the disconnect-replacement banner data for the configuration
    /// that just dropped, so a replacement terminal renders disconnected.
    public func rememberPendingRemoteDisconnectReplacement(configuration: WorkspaceRemoteConfiguration) {
        let reconnectCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.pendingRemoteDisconnectReplacement = PendingRemoteDisconnectReplacement(
            target: configuration.displayTarget,
            reconnectCommand: reconnectCommand?.isEmpty == false ? reconnectCommand : nil
        )
    }

    // MARK: - Local-demotion lifecycle

    /// Drops the remote configuration when the workspace became empty (its last
    /// panel closed) so a remote workspace whose terminals all closed reverts to
    /// a local workspace, unless a disconnect-placeholder is pending or the
    /// configuration is marked to persist after terminal exit.
    public func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard let host else { return }
        guard !host.hostIsDetachingCloseTransaction,
              host.hostHasNoPanels,
              state.remoteConfiguration != nil else { return }
        guard state.pendingRemoteDisconnectReplacement == nil else { return }
        if state.remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    /// After the last remote SSH terminal surface ended, demotes a remote
    /// workspace with no browser panels back to local (full teardown), unless the
    /// configuration persists after terminal exit or the connection is in a
    /// transient/error state that should keep the configuration for retry.
    public func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard let host else { return }
        guard host.hostHasNoActiveRemoteTerminalSurfaces, state.remoteConfiguration != nil else { return }
        if state.remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        if !host.hostHasBrowserPanels {
            if state.remoteConnectionState == .error ||
                state.remoteDaemonStatus.state == .error ||
                state.remoteConnectionState == .connecting ||
                state.remoteConnectionState == .reconnecting ||
                state.remoteConnectionState == .suspended {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    // MARK: - Disconnect-placeholder script

    /// Writes a small shell wrapper that keeps a disconnected remote terminal
    /// visible. The returned path goes to `initialCommand`, which Ghostty runs as
    /// the PTY command. Localized banner strings come from the app-injected
    /// ``RemoteConnectionStrings`` (the package never localizes).
    public func remoteDisconnectPlaceholderScript(target: String, reconnectCommand: String?) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-remote-disconnect-\(UUID().uuidString.lowercased()).sh"
        )
        // Encode the target as base64 and decode it inside the shell. This sidesteps every
        // layer of shell quoting: no matter what the target contains (`$(id)`, backticks,
        // single/double quotes, escape sequences), the shell never sees it as shell syntax.
        // Previous version only escaped backslash and double-quote, which left command
        // substitution and backticks as a live injection vector (Codex P2).
        let encodedTarget = Data(target.utf8).base64EncodedString()
        // Localized banner strings. Both use %s (not %@) because they're rendered by the
        // POSIX printf inside the shell wrapper, not by Swift's String(format:).
        let endedLineFormat = strings.disconnectBannerSessionEndedFormat
        let reconnectLine = strings.disconnectBannerReconnectHint
        let reconnectUnavailableLine = strings.disconnectBannerReconnectUnavailableHint
        // Encode the localized lines the same way as the target, so a translator using
        // backticks or $(…) in a translation string can't unexpectedly execute in the
        // user's local shell. Decoded inline at wrapper startup, then fed to printf.
        let encodedEndedFormat = Data(endedLineFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(reconnectLine.utf8).base64EncodedString()
        let encodedReconnectUnavailableLine = Data(reconnectUnavailableLine.utf8).base64EncodedString()
        let encodedReconnectCommand = Data((reconnectCommand ?? "").utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_disconnect_decode() {
          printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
        }
        cmux_disconnect_target="$(cmux_disconnect_decode '\(encodedTarget)')"
        cmux_disconnect_ended_format="$(cmux_disconnect_decode '\(encodedEndedFormat)')"
        cmux_disconnect_reconnect_line="$(cmux_disconnect_decode '\(encodedReconnectLine)')"
        cmux_disconnect_reconnect_unavailable_line="$(cmux_disconnect_decode '\(encodedReconnectUnavailableLine)')"
        cmux_disconnect_reconnect_command="$(cmux_disconnect_decode '\(encodedReconnectCommand)')"
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m'
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target"
        printf '\\033[0m\\n' >&2
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        rm -f -- "$0" 2>/dev/null || true
        if [ -n "$cmux_disconnect_reconnect_command" ]; then
          printf '\\033[2m%s\\033[0m\\n\\n' "$cmux_disconnect_reconnect_line" >&2
          IFS= read -r _ || exit 0
          cmux_reconnect_cli="${CMUX_BUNDLED_CLI_PATH:-}"
          if [ -z "$cmux_reconnect_cli" ] || [ ! -x "$cmux_reconnect_cli" ]; then
            cmux_reconnect_cli="$(command -v cmux 2>/dev/null || true)"
          fi
          cmux_reconnect_socket="${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}"
          if [ -n "$cmux_reconnect_cli" ] && [ -n "$cmux_reconnect_socket" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
            cmux_reconnect_payload="{\\"workspace_id\\":\\"$CMUX_WORKSPACE_ID\\""
            if [ -n "${CMUX_SURFACE_ID:-}" ]; then
              cmux_reconnect_payload="$cmux_reconnect_payload,\\"surface_id\\":\\"$CMUX_SURFACE_ID\\""
            fi
            cmux_reconnect_payload="$cmux_reconnect_payload}"
            if "$cmux_reconnect_cli" --socket "$cmux_reconnect_socket" rpc workspace.remote.reconnect "$cmux_reconnect_payload" >/dev/null 2>&1; then
              exec /bin/sh -lc "$cmux_disconnect_reconnect_command"
            fi
          fi
          printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
          while IFS= read -r _; do :; done
          exit 0
        fi
        printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
        while IFS= read -r _; do :; done
        exit 0

        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }

    // MARK: - SSH control-master cleanup

    /// Tears down a multiplexed SSH control-master connection for a configuration
    /// whose last remote terminal exited, off the main actor.
    ///
    /// Forwards to the non-generic ``SSHControlMasterCleanup`` runner; static
    /// stored state cannot live on this generic type.
    public static func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        SSHControlMasterCleanup.requestIfNeeded(configuration: configuration)
    }

    /// XCTest seam: scripts the control-master cleanup command instead of
    /// spawning ssh. Forwards to the non-generic runner so the generic type
    /// keeps its historical `RemoteConnectionCoordinator<Host>` API surface.
    public nonisolated static var runSSHControlMasterCommandOverrideForTesting: (([String]) -> Void)? {
        get { SSHControlMasterCleanup.runCommandOverrideForTesting }
        set { SSHControlMasterCleanup.runCommandOverrideForTesting = newValue }
    }
}

/// Non-generic home for the SSH control-master cleanup statics, which Swift
/// forbids on the generic ``RemoteConnectionCoordinator``.
enum SSHControlMasterCleanup {
    static func requestIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let arguments = RemoteControlMasterCleanup().cleanupArguments(configuration: configuration) else { return }
        if let override = runCommandOverrideForTesting {
            override(arguments)
            return
        }

        sshControlMasterCleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = configuration.sshProcessEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }

    private static let sshControlMasterCleanupQueue = DispatchQueue(
        label: "com.cmux.remote-ssh.control-master-cleanup",
        qos: .utility
    )

    /// XCTest seam: scripts the control-master cleanup command instead of
    /// spawning ssh.
    nonisolated(unsafe) static var runCommandOverrideForTesting: (([String]) -> Void)?
}

extension RemoteConnectionCoordinator {
    // MARK: - Notification cooldown key

    /// The remote-error notification cooldown key for `target`, normalized to a
    /// `remote-host:<host>` token so every notification for the same host shares
    /// one cooldown bucket. Prefers the live configuration's destination (the
    /// state this coordinator owns) and falls back to the supplied `target`;
    /// strips any `user@` prefix, trims, and lowercases the host. Returns `nil`
    /// when neither yields a non-empty host (no cooldown bucketing then).
    func remoteNotificationCooldownKey(target: String) -> String? {
        let rawTarget = (state.remoteConfiguration?.destination ?? target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let normalizedHost = rawTarget
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedHost, !normalizedHost.isEmpty else { return nil }
        return "remote-host:\(normalizedHost)"
    }

    // MARK: - Publish receivers (RemoteSessionHosting → state)

    /// Applies a connection-state transition from the session coordinator,
    /// projecting sidebar status entries and notifications and preserving the
    /// proxy-only-error-while-SSH-alive policy.
    public func applyRemoteConnectionStateUpdate(
        _ stateValue: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        guard let host else { return }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            (stateValue == .connecting || stateValue == .reconnecting) &&
                preservesProxyFailureWhileSSHTerminalIsAlive &&
                host.hostHasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if stateValue == .error && proxyOnlyError && preservesProxyFailureWhileSSHTerminalIsAlive {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = stateValue
        }

        state.remoteConnectionState = effectiveState
        state.remoteConnectionDetail = detail
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()

        if stateValue == .suspended {
            let entryDetail = trimmedDetail ?? ""
            let entryValue = String(
                format: strings.suspendedStatusEntryFormat,
                locale: .current,
                target,
                entryDetail
            )
            host.hostSetStatusEntry(
                SidebarStatusEntry(
                    key: host.hostRemoteErrorStatusKey,
                    value: entryValue,
                    icon: "pause.circle",
                    color: nil,
                    timestamp: Date()
                ),
                forKey: host.hostRemoteErrorStatusKey
            )
            let fingerprint = "suspended:\(entryDetail)"
            if state.remoteLastErrorFingerprint != fingerprint {
                state.remoteLastErrorFingerprint = fingerprint
                host.hostAppendSidebarLog(message: entryValue, level: .warning, source: "remote")
                host.hostAddRemoteNotification(
                    title: strings.suspendedNotificationTitle,
                    subtitle: target,
                    body: entryDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: host.hostRemoteNotificationCooldown
                )
            }
            return
        }

        if let trimmedDetail, !trimmedDetail.isEmpty, (stateValue == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            host.hostSetStatusEntry(
                SidebarStatusEntry(
                    key: host.hostRemoteErrorStatusKey,
                    value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    icon: statusIcon,
                    color: nil,
                    timestamp: Date()
                ),
                forKey: host.hostRemoteErrorStatusKey
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if state.remoteLastErrorFingerprint != fingerprint {
                state.remoteLastErrorFingerprint = fingerprint
                host.hostAppendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                host.hostAddRemoteNotification(
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: host.hostRemoteNotificationCooldown
                )
            }
            return
        }

        if stateValue == .connected {
            host.hostRemoveStatusEntry(forKey: host.hostRemoteErrorStatusKey)
            state.remoteLastErrorFingerprint = nil
        }
    }

    /// Applies a daemon status snapshot, projecting the daemon-error sidebar log.
    public func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        guard let host else { return }
        state.remoteDaemonStatus = status
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            state.remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard state.remoteLastDaemonErrorFingerprint != fingerprint else { return }
        state.remoteLastDaemonErrorFingerprint = fingerprint
        host.hostAppendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    /// Applies the shared proxy endpoint, fanning it out to browser panels.
    public func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        guard let host else { return }
        state.remoteProxyEndpoint = endpoint
        host.hostApplyRemoteProxyEndpointToBrowserPanels(endpoint)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
    }

    /// Applies a daemon-heartbeat update.
    public func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        guard let host else { return }
        state.remoteHeartbeatCount = max(0, count)
        state.remoteLastHeartbeatAt = lastSeenAt
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
    }

    /// Applies a detected-remote-ports snapshot, projecting per-surface listening
    /// ports and the port-conflict sidebar entry.
    public func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        guard let host else { return }
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in host.hostRemoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            host.hostRemoveSurfaceListeningPorts(panelId)
        }
        host.hostRemoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                host.hostRemoveSurfaceListeningPorts(panelId)
            } else {
                host.hostSetSurfaceListeningPorts(ports, for: panelId)
            }
        }

        state.remoteDetectedPorts = detected
        state.remoteForwardedPorts = forwarded
        state.remotePortConflicts = conflicts
        host.hostRecomputeListeningPorts()

        if conflicts.isEmpty {
            host.hostRemoveStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
            state.remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        host.hostSetStatusEntry(
            SidebarStatusEntry(
                key: host.hostRemotePortConflictStatusKey,
                value: "SSH port conflicts (\(target)): \(conflictsList)",
                icon: "exclamationmark.triangle.fill",
                color: nil,
                timestamp: Date()
            ),
            forKey: host.hostRemotePortConflictStatusKey
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard state.remoteLastPortConflictFingerprint != fingerprint else { return }
        state.remoteLastPortConflictFingerprint = fingerprint
        host.hostAppendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    /// Clears the per-surface listening ports tracked from remote detection.
    func clearRemoteDetectedSurfacePorts() {
        guard let host else { return }
        for panelId in host.hostRemoteDetectedSurfaceIds {
            host.hostRemoveSurfaceListeningPorts(panelId)
        }
        host.hostRemoteDetectedSurfaceIds = []
    }

    // MARK: - Policy predicates

    static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    private var preservesProxyFailureWhileSSHTerminalIsAlive: Bool {
        state.remoteConfiguration?.transport == .ssh
            && state.activeRemoteTerminalSessionCount > 0
            && state.remoteConfiguration?.terminalStartupCommand?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
