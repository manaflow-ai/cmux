import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

// A TTY-scoped port scan attributes a listening port to a panel through the
// remote process's controlling TTY (`/proc/<pid>/fd/0`). That attribution is
// best-effort and races under load, so a scan can succeed yet report no port
// for a panel whose server is still listening. The coordinator used to treat
// such an empty-but-successful scan as authoritative and drop the port, which
// made the sidebar port badge flicker and shift the surrounding rows. These
// tests drive the queue-confined scan directly through a scripted process
// runner (no wall-clock waits) and assert a transient empty scan keeps the
// last-known port while a sustained absence still clears it.
@Suite("Remote port scan retention")
struct RemotePortScanRetentionTests {
    @Test("A transient empty scan keeps a still-listening port")
    func transientEmptyScanKeepsPort() {
        let runner = ScriptedProcessRunner(stdouts: ["ttys010\t3001\n", ""])
        let host = RecordingRemoteSessionHost()
        let coordinator = Self.makeCoordinator(runner: runner, host: host)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.remotePortScanTTYNames = [panelId: "ttys010"]
            coordinator.performRemotePortScanLocked()
        }
        #expect(host.lastDetected == [3001])

        coordinator.queue.sync {
            coordinator.performRemotePortScanLocked()
        }
        #expect(
            host.lastDetected == [3001],
            "a single empty scan must not drop a still-listening port"
        )

        coordinator.stop()
    }

    @Test("A port absent past the retention limit is dropped")
    func sustainedEmptyScanDropsPort() {
        let emptyScans = [String](
            repeating: "",
            count: RemoteSessionCoordinator.remotePortScanEmptyRetentionLimit + 1
        )
        let runner = ScriptedProcessRunner(stdouts: ["ttys010\t3001\n"] + emptyScans)
        let host = RecordingRemoteSessionHost()
        let coordinator = Self.makeCoordinator(runner: runner, host: host)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.remotePortScanTTYNames = [panelId: "ttys010"]
            coordinator.performRemotePortScanLocked()
        }
        #expect(host.lastDetected == [3001])

        for _ in emptyScans {
            coordinator.queue.sync { coordinator.performRemotePortScanLocked() }
        }
        #expect(
            host.lastDetected == [],
            "a port that stays gone past the retention limit must clear"
        )

        coordinator.stop()
    }

    private static func makeCoordinator(
        runner: RemoteSessionProcessRunning,
        host: RemoteSessionHosting
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
        return RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: UnusedRemoteProxyBroker(),
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

/// Returns a scripted stdout per invocation (holding the last entry once the
/// script is exhausted), so a test can sequence "port found" then "empty scan"
/// deterministically without touching ssh.
private final class ScriptedProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let stdouts: [String]
    private var index = 0

    init(stdouts: [String]) {
        self.stdouts = stdouts
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            let stdout = stdouts[min(index, stdouts.count - 1)]
            index += 1
            return RemoteCommandResult(status: 0, stdout: stdout, stderr: "")
        }
    }
}

/// Captures the most recent published port snapshot so tests can assert what
/// the sidebar would render.
private final class RecordingRemoteSessionHost: RemoteSessionHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastDetected: [Int] = []

    var lastDetected: [Int] { lock.withLock { _lastDetected } }

    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {
        lock.withLock { _lastDetected = detected }
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
        fatalError("UnusedRemoteProxyBroker.acquire is not exercised by port-scan retention tests")
    }

    func listPTY(configuration: WorkspaceRemoteConfiguration) throws -> [[String: Any]] { [] }
    func closePTY(configuration: WorkspaceRemoteConfiguration, sessionID: String) throws {}
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
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        fatalError("UnusedRemoteProxyBroker.startPTYBridge is not exercised by port-scan retention tests")
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
