import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

// Gates the coordinator's remote listening-port discovery on the sidebar
// ports-visibility settings (issue #6123). The backend used to scan ssh
// regardless of `sidebar.showPorts`/`sidebar.hideAllDetails`, so users who
// disabled the port detail could not stop the repeated `/usr/bin/ssh` port
// scans that wedged the control socket and slowed quit.
//
// Every case drives the queue-confined `*Locked` methods directly inside
// `queue.sync`, so the coordinator's serial queue executes them on the calling
// thread with full confinement and no wall-clock waits: the spy process runner
// returns immediately, so `runCount` and the timer/coalesce state are exact.
@Suite("Remote port scan settings gating")
struct RemotePortScanGatingTests {
    @Test("Ready update for an existing proxy endpoint republishes connected")
    func readyForExistingProxyEndpointRepublishesConnected() {
        let runner = SpyProcessRunner()
        let host = RecordingRemoteSessionHost()
        let coordinator = Self.makeCoordinator(runner: runner, host: host, terminalStartupCommand: "true")
        let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 49152)

        coordinator.queue.sync {
            coordinator.proxyEndpoint = endpoint
            coordinator.handleProxyBrokerUpdateLocked(
                .ready(endpoint), leaseGeneration: coordinator.proxyLeaseGeneration)
        }

        #expect(host.connectionStates.map(\.state).contains(.connected))
        #expect(host.connectionStates.last?.detail?.contains("shared local proxy 127.0.0.1:49152") == true)
        coordinator.stop()
    }

    @Test("Disabling stops the host-wide poll timer and spawns no ssh")
    func disablingStopsPollTimer() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, terminalStartupCommand: "true")

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanningEnabledLocked(false)
            coordinator.updateRemotePortPollingStateLocked()
        }

        #expect(coordinator.queue.sync { coordinator.remotePortPollTimer != nil } == false)
        #expect(runner.runCount == 0)
        coordinator.stop()
    }

    @Test("Enabled keeps the host-wide poll timer running and scans (sanity)")
    func enabledStartsPollTimer() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, terminalStartupCommand: "true")

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortPollingStateLocked()
        }

        #expect(coordinator.queue.sync { coordinator.remotePortPollTimer != nil } == true)
        #expect(runner.runCount >= 1)
        coordinator.queue.sync { coordinator.stopRemotePortPollingLocked() }
        coordinator.stop()
    }

    @Test("Disabling suppresses the TTY-scoped scan ssh")
    func disablingSuppressesScanSSH() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys010"])
            coordinator.updateRemotePortScanningEnabledLocked(false)
            coordinator.performRemotePortScanLocked()
        }

        #expect(runner.runCount == 0)
        coordinator.stop()
    }

    @Test("Enabled TTY-scoped scan spawns one ssh (sanity)")
    func enabledScanSpawnsSSH() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys010"])
            coordinator.performRemotePortScanLocked()
        }

        #expect(runner.runCount == 1)
        coordinator.stop()
    }

    @Test("A transient empty TTY scan keeps the published port")
    func transientEmptyTTYScanKeepsPublishedPort() {
        let runner = SpyProcessRunner(results: [
            RemoteCommandResult(status: 0, stdout: "ttys010\t4200\n\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010\n", stderr: ""),
            RemoteCommandResult(
                status: 0,
                stdout: "\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010\n",
                stderr: ""
            ),
        ])
        let host = RecordingRemoteSessionHost()
        let coordinator = Self.makeCoordinator(runner: runner, host: host)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys010"])
            coordinator.performRemotePortScanLocked()
            coordinator.performRemotePortScanLocked()
        }

        #expect(host.detectedPorts == [4200])
        #expect(host.detectedPortsByPanel[panelId] == [4200])
        coordinator.stop()
    }

    @Test("Repeated incomplete TTY scans fail closed only for fallback retention")
    func repeatedIncompleteTTYScansExpireFallbackOnly() {
        let runner = SpyProcessRunner(results: [
            RemoteCommandResult(status: 0, stdout: "ttys010\t4200\n\(RemoteSessionCoordinator.remoteTTYPortScanCompleteMarker)\tttys010\n", stderr: ""),
            RemoteCommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let host = RecordingRemoteSessionHost()
        let coordinator = Self.makeCoordinator(runner: runner, host: host)
        let panelId = UUID()
        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys010"])
            coordinator.performRemotePortScanLocked()
            coordinator.remotePortPollState.apply(observedPorts: [8080], mode: .hostWide, completeness: .complete)
            coordinator.keepPolledRemotePortsUntilTTYScan = true
            for _ in 0..<3 { coordinator.performRemotePortScanLocked() }
        }
        #expect(host.detectedPortsByPanel[panelId] == [4200])
        #expect(host.detectedPorts == [4200])
        coordinator.stop()
    }

    @Test("Disabling makes a scan kick schedule no burst")
    func disablingDropsScanKick() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys011"])
            coordinator.updateRemotePortScanningEnabledLocked(false)
            coordinator.kickRemotePortScanLocked(panelId: panelId, reason: .command)
        }

        let scheduledNothing = coordinator.queue.sync {
            coordinator.remotePortScanCoalesceToken == nil
                && coordinator.remotePortScanPendingReason == nil
                && !coordinator.remotePortScanBurstActive
        }
        #expect(scheduledNothing)
        #expect(runner.runCount == 0)
        coordinator.stop()
    }

    @Test("Toggling off tears down active polling and clears detected ports")
    func togglingOffTearsDownActivePolling() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, terminalStartupCommand: "true")

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.remotePortPollState.apply(observedPorts: [4321], mode: .hostWide, completeness: .complete)
            coordinator.updateRemotePortPollingStateLocked()
        }
        #expect(coordinator.queue.sync { coordinator.remotePortPollTimer != nil } == true)

        coordinator.queue.sync {
            coordinator.updateRemotePortScanningEnabledLocked(false)
        }

        let tornDown = coordinator.queue.sync {
            coordinator.remotePortPollTimer == nil && coordinator.remotePortPollState.publishedPorts.isEmpty
        }
        #expect(tornDown)
        coordinator.stop()
    }

    @Test("Disabling resets the host-wide delta baseline and bootstrap retry budget")
    func disablingResetsHiddenScannerState() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, relayPort: 41000)

        coordinator.queue.sync {
            coordinator.daemonReady = true
            // Simulate state accumulated before the user hides ports: a
            // host-wide-delta baseline and an exhausted bootstrap TTY retry
            // budget.
            coordinator.remotePortPollState.apply(
                observedPorts: [3000, 4000], mode: .hostWideDelta, completeness: .complete
            )
            coordinator.bootstrapRemoteTTYRetryCount = RemoteSessionCoordinator.bootstrapRemoteTTYRetryLimit
            coordinator.updateRemotePortScanningEnabledLocked(false)
        }

        let reset = coordinator.queue.sync {
            coordinator.remotePortPollState.baselinePorts == nil
                && coordinator.bootstrapRemoteTTYRetryCount == 0
        }
        #expect(reset)
        coordinator.stop()
    }

    @Test("Disabling suppresses bootstrap TTY resolution ssh")
    func disablingSuppressesBootstrapTTYResolution() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, relayPort: 41000)

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanningEnabledLocked(false)
            coordinator.requestBootstrapRemoteTTYIfNeededLocked()
        }

        #expect(runner.runCount == 0)
        coordinator.stop()
    }

    @Test("Enabled bootstrap TTY resolution spawns ssh (sanity)")
    func enabledBootstrapTTYResolutionSpawnsSSH() {
        // A valid TTY in stdout resolves on the first pass, so no 0.5s retry is
        // scheduled and the exact run count cannot race a delayed retry.
        let runner = SpyProcessRunner(
            result: RemoteCommandResult(status: 0, stdout: "ttys005\n", stderr: "")
        )
        let coordinator = Self.makeCoordinator(runner: runner, relayPort: 41000)

        let (count, resolved) = coordinator.queue.sync { () -> (Int, Bool) in
            coordinator.daemonReady = true
            coordinator.requestBootstrapRemoteTTYIfNeededLocked()
            return (runner.runCount, coordinator.bootstrapRemoteTTYResolved)
        }

        #expect(count == 1)
        #expect(resolved)
        coordinator.stop()
    }

    @Test("Re-enabling after a disable restarts the poll timer")
    func reEnablingRestartsPolling() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner, terminalStartupCommand: "true")

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanningEnabledLocked(false)
            coordinator.updateRemotePortPollingStateLocked()
        }
        #expect(coordinator.queue.sync { coordinator.remotePortPollTimer != nil } == false)

        coordinator.queue.sync {
            coordinator.updateRemotePortScanningEnabledLocked(true)
        }

        #expect(coordinator.queue.sync { coordinator.remotePortPollTimer != nil } == true)
        coordinator.queue.sync { coordinator.stopRemotePortPollingLocked() }
        coordinator.stop()
    }

    @Test("Baked VM preflight ignores persistent PTY capabilities")
    func bakedVMPreflightIgnoresPersistentPTYCapabilities() {
        let runner = SpyProcessRunner()
        let coordinator = Self.makeCoordinator(
            runner: runner,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
        )

        #expect(coordinator.requiredDaemonCapabilities == [
            "proxy.stream.push",
            "pty.session",
            "pty.session.token",
            "pty.write.notification",
            "pty.resize.notification",
            "pty.session.persistent_daemon",
        ])
        #expect(coordinator.bakedDaemonPreflightRequiredCapabilities == ["proxy.stream.push"])
        coordinator.stop()
    }

    // MARK: - Harness

    static func makeCoordinator(
        runner: SpyProcessRunner,
        host: any RemoteSessionHosting = PortScanNoopRemoteSessionHost(),
        terminalStartupCommand: String? = nil,
        relayPort: Int? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        skipDaemonBootstrap: Bool = false
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: terminalStartupCommand,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
        return RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: UnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: NoopReachabilityProbe(),
            relayCommandRewriter: PassthroughRelayCommandRewriter(),
            buildInfo: StubBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            )
        )
    }
}

// MARK: - Stubs

final class SpyProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _runCount = 0
    private var _requests: [RemoteProcessRequest] = []
    private let results: [RemoteCommandResult]

    init(result: RemoteCommandResult = RemoteCommandResult(status: 0, stdout: "", stderr: "")) {
        results = [result]
    }

    init(results: [RemoteCommandResult]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    var runCount: Int { lock.withLock { _runCount } }
    var requests: [RemoteProcessRequest] { lock.withLock { _requests } }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            _requests.append(request)
            let result = results[min(_runCount, results.count - 1)]
            _runCount += 1
            return result
        }
    }
}
struct PortScanNoopRemoteSessionHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}
final class RecordingRemoteSessionHost: RemoteSessionHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _connectionStates: [(state: WorkspaceRemoteConnectionState, detail: String?)] = []
    private var _detectedPortsByPanel: [UUID: [Int]] = [:]
    private var _detectedPorts: [Int] = []

    var connectionStates: [(state: WorkspaceRemoteConnectionState, detail: String?)] {
        lock.withLock { _connectionStates }
    }
    var detectedPortsByPanel: [UUID: [Int]] { lock.withLock { _detectedPortsByPanel } }
    var detectedPorts: [Int] { lock.withLock { _detectedPorts } }

    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        lock.withLock {
            _connectionStates.append((state, detail))
        }
    }

    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {
        lock.withLock {
            _detectedPortsByPanel = detectedByPanel
            _detectedPorts = detected
        }
    }
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

/// The port-scan path never acquires a proxy lease or touches PTY sessions, so
/// the unreachable members trap if a future change starts exercising them.
private final class UnusedRemoteProxyBroker: RemoteProxyBrokering, @unchecked Sendable {
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        fatalError("UnusedRemoteProxyBroker.acquire is not exercised by port-scan gating tests")
    }

    func listPTY(configuration: WorkspaceRemoteConfiguration) throws -> [[String: Any]] { [] }
    func closePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        deadline: DispatchTime
    ) throws {}
    func ptySessionLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws -> RemotePTYSessionLifecycle { .active }
    func acknowledgePTYLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws {}
    func acknowledgePTYLifecycleAfterWrapperEnd(sessionID: String, lifecycleID: String) -> Bool { false }
    func resizePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {}
    func detachPTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {}
    func startPTYBridge(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        fatalError("UnusedRemoteProxyBroker.startPTYBridge is not exercised by port-scan gating tests")
    }
}

private struct NoopReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

private struct PassthroughRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

private struct StubBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
