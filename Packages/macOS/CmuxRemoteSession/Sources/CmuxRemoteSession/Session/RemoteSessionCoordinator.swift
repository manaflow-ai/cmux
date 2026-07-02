public import CmuxCore
public import CmuxRemoteDaemon
public import CmuxRemoteWorkspace
public import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// Per-workspace remote-session lifecycle coordinator: owns the SSH/SCP
/// orchestration, cmuxd-remote bootstrap and install, the reverse CLI relay,
/// the persistent-PTY bridge entry points, remote port scanning, and the
/// reconnect/suspend policy for one configured remote workspace.
///
/// Faithful lift of the app's `WorkspaceRemoteSessionController` behind
/// injected seams: publishes ride ``RemoteSessionHosting`` (the app adapter
/// owns the main-queue hop and the stale-controller guard), subprocesses ride
/// ``RemoteSessionProcessRunning``, `Bundle.main` reads ride
/// ``RemoteSessionBuildInfoProviding``, and app-localized strings ride
/// ``RemoteSessionStrings``/`RemoteDaemonStrings`. SSH/SCP argv, bootstrap
/// command strings, handshake and ready lines, retry cadences, port-scan
/// behavior, and error text are pinned legacy behavior.
///
/// ## Isolation design
///
/// This is deliberately a queue-confined class, not an actor and not
/// `@MainActor` (the blueprint's eventual `@MainActor @Observable` shape is
/// deferred until callers can await):
///
/// - Every mutator and every reader of the session state runs on the private
///   serial utility `queue` (the `*Locked` methods). Long blocking SSH/SCP
///   execs run ON that queue by design, so the state machine can never be
///   `@MainActor`.
/// - The synchronous PTY entry points (`listPTYSessions`,
///   `startPTYBridge`, `resizePTY`, `detachPTYSession`) must deliver results
///   to callers that cannot await (socket command handlers blocking a real
///   thread). An actor would force semaphore re-entry bridges at every call
///   site, the exact pattern this refactor bans; the same ruling as the
///   lifted RPC client, proxy tunnel, and proxy broker.
/// - Published state lives on the app's workspace model; the coordinator only
///   pushes snapshots through ``RemoteSessionHosting``, so there is no
///   observable state here to host on the main actor.
///
/// `@unchecked Sendable` because callbacks handed to the broker, Dispatch
/// timers, clock tasks, and Process handlers capture `self` from other
/// contexts by long-standing contract and immediately hop onto `queue`;
/// queue confinement is the safety argument, same as the lifted
/// tunnel/broker.
public final class RemoteSessionCoordinator: @unchecked Sendable {
    // MARK: - Collaborators (immutable after init)

    let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    let queueKey = DispatchSpecificKey<Void>()
    /// One-way publish seam to the owning workspace model (the app adapter
    /// binds the controller ID and owns the main-queue hop).
    let host: any RemoteSessionHosting
    let configuration: WorkspaceRemoteConfiguration
    let proxyBroker: any RemoteProxyBrokering
    let manifestRepository: RemoteDaemonManifestRepository
    let processRunner: any RemoteSessionProcessRunning
    let reachabilityProbe: any RemoteHostReachabilityProbing
    let relayCommandRewriter: any RemoteRelayCommandRewriting
    let buildInfo: any RemoteSessionBuildInfoProviding
    let daemonStrings: RemoteDaemonStrings
    let strings: RemoteSessionStrings
    /// Sleep seam for every legacy `asyncAfter` delay (reconnect backoff,
    /// relay restart, bootstrap-TTY retry, port-scan coalesce and burst).
    let clock: any RemoteProxyRetryClock
    let reconnectPolicy = RemoteReconnectPolicy()

    // MARK: - Queue-confined state
    //
    // Every var below is confined to `queue` (see the isolation essay).
    // Internal (not private) only so the coordinator's same-module extension
    // files can reach them; nothing outside this type may touch them.

    var isStopping = false
    var proxyLease: RemoteProxyLease?
    var proxyEndpoint: BrowserProxyEndpoint?
    var daemonReady = false
    var daemonBootstrapVersion: String?
    var daemonRemotePath: String?
    var reverseRelayProcess: Process?
    var reverseRelayControlMasterForwardSpec: String?
    var cliRelayServer: RemoteCLIRelayServer?
    var remotePortScanTTYNames: [UUID: String] = [:]
    var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    var remotePortScanBurstActive = false
    var remotePortScanActiveReason: PortScanKickReason?
    var remotePortScanPendingReason: PortScanKickReason?
    var remotePortScanGeneration: UInt64 = 0
    var remotePortScanCoalesceTask: Task<Void, Never>?
    var remotePortScanCoalesceToken: UUID?
    var remotePortScanBurstTask: Task<Void, Never>?
    var remotePortPollTimer: (any DispatchSourceTimer)?
    var remotePortPollMode: RemotePortPollingMode?
    var polledRemotePorts: [Int] = []
    var remotePortPollBaselinePorts: Set<Int>?
    var keepPolledRemotePortsUntilTTYScan = false
    /// Whether remote listening-port discovery (TTY-scoped scan bursts and the
    /// host-wide/delta poll fallback) may spawn ssh. The app derives this from
    /// the sidebar ports-visibility settings (`sidebar.showPorts` and
    /// `sidebar.hideAllDetails`) via ``updateRemotePortScanningEnabled(_:)``;
    /// when ports are not displayed there is nothing for the scans to populate,
    /// so the whole ssh-spawning path is suspended.
    var remotePortScanningEnabled = true
    var bootstrapRemoteTTYResolved = false
    var bootstrapRemoteTTYRetryTask: Task<Void, Never>?
    var bootstrapRemoteTTYRetryToken: UUID?
    var bootstrapRemoteTTYFetchInFlight = false
    var bootstrapRemoteTTYRetryCount = 0
    var reverseRelayStderrPipe: Pipe?
    var reverseRelayRestartTask: Task<Void, Never>?
    var reverseRelayRestartToken: UUID?
    var reverseRelayStderrBuffer = ""
    var reconnectRetryCount = 0
    var reconnectTask: Task<Void, Never>?
    var reconnectToken: UUID?
    var consecutiveUnreachableProbeCount = 0
    var reconnectSuspended = false
    var reachabilityProbeGeneration: UInt64 = 0
    var heartbeatCount: Int = 0
    var connectionAttemptStartedAt: Date?
    var pendingPTYBridgeStarts: [UUID: PendingPTYBridgeStart] = [:]
    var remoteRelayWorkspaceAliases: [UUID: UUID] = [:]
    var remoteRelaySurfaceAliases: [UUID: UUID] = [:]
    /// Dev-only source-fingerprint cache: `.none` = not computed yet,
    /// `.some(nil)` = computed and unavailable (legacy process-wide
    /// `static let` cache, made per-coordinator with the build-info seam).
    var remoteDaemonSourceFingerprintCache: String??

    /// Grace period the relay-startup failure probe waits for an `ssh -N -R`
    /// transport that may exit immediately (public because it is the default
    /// argument of the test-pinned ``reverseRelayStartupFailureDetail(process:stderrPipe:gracePeriod:)``).
    public static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    /// Creates a coordinator for one remote-workspace connection attempt.
    ///
    /// - Parameters:
    ///   - host: Publish seam back to the owning workspace model.
    ///   - configuration: The remote connection configuration (immutable for
    ///     this coordinator's lifetime; reconnects construct a fresh one).
    ///   - proxyBroker: Process-wide proxy-tunnel broker (one shared tunnel
    ///     per remote transport), injected from the app hub.
    ///   - manifestRepository: cmuxd-remote manifest/binary-cache repository.
    ///   - processRunner: Blocking subprocess seam (ssh/scp/dev go build).
    ///   - reachabilityProbe: SSH endpoint reachability seam for the
    ///     reconnect-suspend policy.
    ///   - relayCommandRewriter: Alias-aware CLI relay command rewriter.
    ///   - buildInfo: App-build inputs (`Bundle.main` stays app-side).
    ///   - daemonStrings: App-localized daemon error strings.
    ///   - strings: App-localized connection-state strings.
    ///   - clock: Sleep seam driving every retry/backoff delay (production
    ///     default: the continuous clock).
    public init(
        host: any RemoteSessionHosting,
        configuration: WorkspaceRemoteConfiguration,
        proxyBroker: any RemoteProxyBrokering,
        manifestRepository: RemoteDaemonManifestRepository,
        processRunner: any RemoteSessionProcessRunning,
        reachabilityProbe: any RemoteHostReachabilityProbing,
        relayCommandRewriter: any RemoteRelayCommandRewriting,
        buildInfo: any RemoteSessionBuildInfoProviding,
        daemonStrings: RemoteDaemonStrings,
        strings: RemoteSessionStrings,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) {
        self.host = host
        self.configuration = configuration
        self.proxyBroker = proxyBroker
        self.manifestRepository = manifestRepository
        self.processRunner = processRunner
        self.reachabilityProbe = reachabilityProbe
        self.relayCommandRewriter = relayCommandRewriter
        self.buildInfo = buildInfo
        self.daemonStrings = daemonStrings
        self.strings = strings
        self.clock = clock
        queue.setSpecific(key: queueKey, value: ())
    }

    /// The capabilities advertised by the cmuxd-remote baked into the Freestyle snapshot
    /// (scratch/vm-experiments/images/install.sh pins v0.63.2). Keep this in lockstep with
    /// the daemon's `hello` response — if the baked version advertises a new capability,
    /// bump it here too.
    static func bakedVMDaemonHello() -> DaemonHello {
        DaemonHello(
            name: "cmuxd-remote",
            version: "v0.63.2-baked",
            capabilities: [
                "session.basic",
                "session.resize.min",
                "proxy.http_connect",
                "proxy.socks5",
                "proxy.stream",
                "proxy.stream.push",
            ],
            remotePath: "/usr/local/bin/cmuxd-remote"
        )
    }

    // MARK: - Lifecycle

    /// Begins the connection attempt on the coordinator's queue.
    public func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    /// Stops the session: tears down the relay, releases the proxy lease,
    /// fails parked PTY-bridge starts, and publishes cleared state.
    /// Synchronous when already on the coordinator queue.
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    /// Forwards the latest session-restore ID aliases to the CLI relay so
    /// relayed commands can be rewritten onto live workspace/surface IDs.
    public func updateRemoteRelayIDAliases(workspaceAliases: [UUID: UUID], surfaceAliases: [UUID: UUID]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.remoteRelayWorkspaceAliases = workspaceAliases
            self.remoteRelaySurfaceAliases = surfaceAliases
            self.cliRelayServer?.updateRemoteRelayIDAliases(
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases
            )
        }
    }

    func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        cancelReconnectRetryLocked()
        reconnectRetryCount = 0
        consecutiveUnreachableProbeCount = 0
        reconnectSuspended = false
        reachabilityProbeGeneration &+= 1
        cancelReverseRelayRestartLocked()
        cancelRemotePortScanCoalesceLocked()
        stopReverseRelayLocked()
        remotePortScanGeneration &+= 1
        remotePortScanBurstTask?.cancel()
        remotePortScanBurstTask = nil
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        remotePortScanTTYNames.removeAll()
        remoteScannedPortsByPanel.removeAll()
        stopRemotePortPollingLocked()
        polledRemotePorts = []
        remotePortPollBaselinePorts = nil
        keepPolledRemotePortsUntilTTYScan = false
        bootstrapRemoteTTYResolved = false
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYFetchInFlight = false
        bootstrapRemoteTTYRetryCount = 0
        failPendingPTYBridgeStartsLocked("remote daemon is not ready")

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        if configuration.transport != .local {
            Self.killOrphanedRemoteSSHProcesses(
                destination: configuration.destination,
                relayPort: configuration.relayPort,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )
        }
        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        // The armed retry (if any) is consumed by this attempt; a stale fire
        // is dropped by the token guard (legacy dropped the work-item
        // reference here).
        reconnectTask = nil
        reconnectToken = nil
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYFetchInFlight = false
        if remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = false
            bootstrapRemoteTTYRetryCount = 0
        }
        let connectDetail: String
        let bootstrapDetail: String
        let connectionState: WorkspaceRemoteConnectionState
        if reconnectRetryCount > 0 {
            connectionState = .reconnecting
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectionState = .connecting
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(connectionState, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let requiredCapabilities = requiredDaemonCapabilities
            let hello: DaemonHello
            if configuration.transport == .local {
                hello = try bootstrapLocalDaemonLocked(requiredCapabilities: requiredCapabilities)
            } else if configuration.skipDaemonBootstrap {
                // Cloud-VM path: cmuxd-remote is pre-baked in the image and exposed via
                // systemd socket activation at /run/cmuxd-remote.sock. We skip the probe,
                // upload, and stdio-hello steps entirely — they all depend on ssh-exec
                // channel I/O, which the Freestyle gateway doesn't forward.
                hello = Self.bakedVMDaemonHello()
                debugLog("remote.bootstrap.skipped reason=vm-baked remotePath=\(hello.remotePath)")
            } else {
                hello = try bootstrapDaemonLocked(requiredCapabilities: requiredCapabilities)
            }
            let preflightRequiredCapabilities = configuration.skipDaemonBootstrap
                ? bakedDaemonPreflightRequiredCapabilities
                : requiredCapabilities
            let missingCapabilities = Self.missingRequiredCapabilities(
                preflightRequiredCapabilities,
                in: hello.capabilities
            )
            guard missingCapabilities.isEmpty else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: daemonStrings.missingRequiredCapabilitiesMessage(missingCapabilities),
                    NSDebugDescriptionErrorKey: "remote daemon missing required capability \(missingCapabilities.joined(separator: ","))",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            if configuration.transport == .local {
                startProxyLocked()
            } else if configuration.skipDaemonBootstrap {
                debugLog("remote.relay.skipped reason=vm-baked transport=\(configuration.transport.rawValue)")
                if configuration.daemonWebSocketEndpoint != nil {
                    startProxyLocked()
                } else {
                    // SSH-only cloud VM fallback cannot use ssh-exec or local socket forwarding
                    // through provider gateways. Keep the shell connected and leave proxy off.
                    publishState(
                        .connected,
                        detail: String(format: strings.connectedVMNoProxyFormat, configuration.displayTarget)
                    )
                }
            } else {
                startReverseRelayLocked(remotePath: hello.remotePath)
                requestBootstrapRemoteTTYIfNeededLocked()
                startProxyLocked()
            }
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon bootstrap failed: \(Self.userFacingRemoteDaemonBootstrapErrorMessage(error, strings: daemonStrings))\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = proxyBroker.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    func handleProxyBrokerUpdateLocked(_ update: RemoteProxyBrokerUpdate) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                if reconnectRetryCount > 0 {
                    publishState(
                        .reconnecting,
                        detail: "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
                    )
                } else {
                    publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
                }
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            cancelReconnectRetryLocked()
            reconnectRetryCount = 0
            consecutiveUnreachableProbeCount = 0
            // A live connection ends any suspension; without this a future
            // failure would hit the suspended guard and never reschedule.
            reconnectSuspended = false
            reachabilityProbeGeneration &+= 1
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                fulfillPendingPTYBridgeStartsLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            fulfillPendingPTYBridgeStartsLocked()
            updateRemotePortPollingStateLocked()
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            requestBootstrapRemoteTTYIfNeededLocked()
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            remotePortScanGeneration &+= 1
            remotePortScanBurstTask?.cancel()
            remotePortScanBurstTask = nil
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            remotePortScanPendingReason = nil
            cancelRemotePortScanCoalesceLocked()
            remoteScannedPortsByPanel.removeAll()
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            keepPolledRemotePortsUntilTTYScan = false
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            failPendingPTYBridgeStartsLocked("remote daemon is not ready")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let retrySchedule = scheduleReconnectLocked(baseDelay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    // MARK: - Publishing (one-way, through the host seam)

    func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        host.publishConnectionState(state, detail: detail)
    }

    func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        host.publishDaemonStatus(status)
    }

    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        host.publishProxyEndpoint(endpoint)
    }

    func publishPortsSnapshotLocked() {
        let detectedByPanel = remotePortScanTTYNames.keys.reduce(into: [UUID: [Int]]()) { result, panelId in
            result[panelId] = remoteScannedPortsByPanel[panelId] ?? []
        }
        let detected = Array(
            Set(polledRemotePorts)
                .union(detectedByPanel.values.flatMap { $0 })
        ).sorted()
        host.publishPortsSnapshot(detectedByPanel: detectedByPanel, detected: detected)
    }

    func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        host.publishHeartbeat(count: heartbeatCount, lastSeenAt: Date())
    }

    func publishBootstrapRemoteTTY(_ ttyName: String) {
        host.publishBootstrapRemoteTTY(ttyName)
    }

    // MARK: - Capabilities

    var requiredDaemonCapabilities: [String] {
        RemoteDaemonRPCClient.requiredCapabilities(for: configuration)
    }

    var bakedDaemonPreflightRequiredCapabilities: [String] {
        requiredDaemonCapabilities.filter {
            $0 != RemoteDaemonRPCClient.requiredPTYSessionCapability &&
                $0 != RemoteDaemonRPCClient.requiredPTYSessionTokenCapability &&
                $0 != RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability && $0 != RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability
        }
    }

    static func missingRequiredCapabilities(_ required: [String], in capabilities: [String]) -> [String] {
        RemoteDaemonRPCClient.missingRequiredCapabilities(required, in: capabilities)
    }

    /// Maps a bootstrap failure to the user-facing message: capability
    /// failures collapse to the app-localized missing-capability string,
    /// anything else surfaces its own description. Static because tests pin
    /// it directly against raw errors; the strings ride in explicitly
    /// (legacy read the app-localized strings in place).
    public static func userFacingRemoteDaemonBootstrapErrorMessage(
        _ error: any Error,
        strings: RemoteDaemonStrings
    ) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYSessionCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYSessionTokenCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) || lowered.contains(RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability) {
            return strings.missingRequiredCapabilitiesMessage([
                RemoteDaemonRPCClient.requiredPTYSessionCapability,
            ])
        }
        return message.isEmpty ? "remote daemon bootstrap failed" : message
    }

    // MARK: - Subprocess execution (through the runner seam)

    func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> RemoteCommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: stdin,
            timeout: timeout
        )
    }

    func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: (any RemoteTransferCancelling)? = nil
    ) throws -> RemoteCommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: (any RemoteTransferCancelling)? = nil
    ) throws -> RemoteCommandResult {
        try processRunner.run(
            RemoteProcessRequest(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                stdin: stdin,
                timeout: timeout
            ),
            operation: operation
        )
    }

    // MARK: - Debug logging

    func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        CMUXDebugLog.logDebugEvent(message())
#endif
    }

    func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(\.shellSingleQuoted)
            .joined(separator: " ")
    }

    static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
