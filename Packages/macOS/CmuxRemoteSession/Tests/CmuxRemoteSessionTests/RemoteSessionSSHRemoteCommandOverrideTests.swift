import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

// A host ssh_config with `RemoteCommand …` (often paired with `RequestTTY
// yes`) must not break the coordinator's non-interactive ssh plumbing
// (https://github.com/manaflow-ai/cmux/issues/7246): every batch exec —
// bootstrap probes, installer hops, port scans, upload cleanup, relay
// metadata — appends its own positional remote command, which OpenSSH
// refuses while a configured RemoteCommand is in effect ("Cannot execute
// command-line and remote command.", exit 255). Batch plumbing must also pin
// `RequestTTY=no` so a host `RequestTTY force` cannot corrupt parsed pipes
// with a remote PTY's CRLF conversion.
@Suite("Coordinator batch ssh argv overrides a host-configured RemoteCommand")
struct RemoteSessionSSHRemoteCommandOverrideTests {
    @Test("Port-scan exec overrides RemoteCommand and disables TTY allocation")
    func portScanExecOverridesHostConfiguredRemoteCommand() {
        let runner = RecordingProcessRunner()
        let coordinator = Self.makeCoordinator(runner: runner)
        let panelId = UUID()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.updateRemotePortScanTTYsLocked([panelId: "ttys010"])
            coordinator.performRemotePortScanLocked()
        }
        defer { coordinator.stop() }

        let requests = runner.requests
        #expect(requests.count == 1)
        guard let request = requests.first else { return }
        #expect(request.executable == "/usr/bin/ssh")
        #expect(Self.consecutive(request.arguments, "-o", "RemoteCommand=none"))
        #expect(Self.consecutive(request.arguments, "-o", "RequestTTY=no"))

        let overrideIndex = Self.pairIndex(request.arguments, "-o", "RemoteCommand=none")
        let destinationIndex = request.arguments.firstIndex(of: "user@example.test")
        #expect(overrideIndex != nil)
        #expect(destinationIndex != nil)
        if let overrideIndex, let destinationIndex {
            #expect(overrideIndex < destinationIndex)
        }
    }

    @Test("Batch args place the override ahead of caller-configured ssh options")
    func batchArgumentsPlaceOverrideBeforeConfiguredOptions() {
        // OpenSSH uses the first obtained value per option, so the override
        // must precede the configuration's own -o options to also win over a
        // caller-supplied RemoteCommand, not only over ssh_config.
        let runner = RecordingProcessRunner()
        let coordinator = Self.makeCoordinator(
            runner: runner,
            sshOptions: ["RemoteCommand=sudo su -", "RequestTTY=yes"]
        )
        defer { coordinator.stop() }

        let arguments = coordinator.sshCommonArguments(batchMode: true)
        let overrideIndex = Self.pairIndex(arguments, "-o", "RemoteCommand=none")
        let configuredIndex = Self.pairIndex(arguments, "-o", "RemoteCommand=sudo su -")
        #expect(overrideIndex != nil)
        #expect(configuredIndex != nil)
        if let overrideIndex, let configuredIndex {
            #expect(overrideIndex < configuredIndex)
        }
        let ttyIndex = Self.pairIndex(arguments, "-o", "RequestTTY=no")
        let configuredTTYIndex = Self.pairIndex(arguments, "-o", "RequestTTY=yes")
        #expect(ttyIndex != nil)
        #expect(configuredTTYIndex != nil)
        if let ttyIndex, let configuredTTYIndex {
            #expect(ttyIndex < configuredTTYIndex)
        }
    }

    @Test("File-backed SSH exec overrides a configured StdinNull")
    func fileBackedSSHExecOverridesConfiguredStdinNull() throws {
        let runner = RecordingProcessRunner()
        let coordinator = Self.makeCoordinator(
            runner: runner,
            sshOptions: ["StdinNull=yes"]
        )
        defer { coordinator.stop() }

        let localFile = URL(fileURLWithPath: "/tmp/cmux-test-helper")
        _ = try coordinator.sshExec(
            arguments: coordinator.sshCommonArguments(batchMode: true) + [
                "user@example.test",
                "sh -c 'cat > remote-helper'",
            ],
            stdinFile: localFile,
            timeout: 1
        )

        let request = try #require(runner.requests.first)
        #expect(request.stdinFile == localFile)
        let overrideIndex = Self.pairIndex(request.arguments, "-o", "StdinNull=no")
        let configuredIndex = Self.pairIndex(request.arguments, "-o", "StdinNull=yes")
        #expect(overrideIndex != nil)
        #expect(configuredIndex != nil)
        if let overrideIndex, let configuredIndex {
            #expect(overrideIndex < configuredIndex)
        }
    }

    // MARK: - Helpers

    private static func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        pairIndex(args, a, b) != nil
    }

    private static func pairIndex(_ args: [String], _ a: String, _ b: String) -> Int? {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return i
        }
        return nil
    }

    // MARK: - Harness

    private static func makeCoordinator(
        runner: RecordingProcessRunner,
        sshOptions: [String] = []
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: sshOptions,
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
            host: NoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: SSHOverrideNoopReachabilityProbe(),
            relayCommandRewriter: SSHOverridePassthroughRelayCommandRewriter(),
            buildInfo: SSHOverrideStubBuildInfo(),
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

/// Records every subprocess request and returns an injected response.
/// Synchronization: the lock guards request storage; `response` is immutable
/// and `@Sendable`, which makes the unchecked conformance safe.
final class RecordingProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    typealias Response = @Sendable (RemoteProcessRequest) throws -> RemoteCommandResult

    private let lock = NSLock()
    private var _requests: [RemoteProcessRequest] = []
    private let response: Response

    init(
        response: @escaping Response = { _ in
            RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
    ) {
        self.response = response
    }

    var requests: [RemoteProcessRequest] { lock.withLock { _requests } }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock { _requests.append(request) }
        return try response(request)
    }
}

struct NoopRemoteSessionHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

final class SSHOverrideUnusedRemoteProxyBroker: RemoteProxyBrokering, @unchecked Sendable {
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        fatalError("SSHOverrideUnusedRemoteProxyBroker.acquire is not exercised by these tests")
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
        fatalError("SSHOverrideUnusedRemoteProxyBroker.startPTYBridge is not exercised by these tests")
    }
}

struct SSHOverrideNoopReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

struct SSHOverridePassthroughRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

struct SSHOverrideStubBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
