import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

@Suite("Remote daemon upload")
struct RemoteDaemonUploadTests {
    @Test("Slash SSH aliases upload the daemon over ssh stdin instead of scp host-path parsing")
    func slashSSHAliasUploadsDaemonOverSSHStdin() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-ssh-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let localBinary = directoryURL.appendingPathComponent("cmuxd-remote", isDirectory: false)
        let binaryData = Data([0x7f, 0x45, 0x4c, 0x46, 0x63, 0x6d, 0x75, 0x78])
        try binaryData.write(to: localBinary)

        let runner = RecordingDaemonUploadProcessRunner()
        let coordinator = Self.makeCoordinator(destination: "prod/web", runner: runner)
        defer { coordinator.stop() }
        let location = try RemoteSessionCoordinator.remoteDaemonInstallLocation(
            version: "0.64.16",
            goOS: "linux",
            goArch: "arm64",
            homeDirectory: "/home/ubuntu"
        )

        try coordinator.queue.sync {
            try coordinator.uploadRemoteDaemonBinaryLocked(localBinary: localBinary, location: location)
        }

        let requests = runner.requests
        #expect(!requests.contains(where: { $0.executable == "/usr/bin/scp" }))

        let uploadRequest = try #require(requests.first { request in
            request.executable == "/usr/bin/ssh" &&
                (request.arguments.last?.contains("cat >") ?? false)
        })
        #expect(uploadRequest.stdin == binaryData)
        // `-T` disables pty allocation so a `RequestTTY force` config can't put
        // the raw binary on a pty and corrupt it via CR/LF translation.
        #expect(uploadRequest.arguments.contains("-T"))
        #expect(uploadRequest.arguments.contains("prod/web"))
        #expect(!uploadRequest.arguments.contains(where: { $0.hasPrefix("prod/web:") }))
        #expect(uploadRequest.arguments.last?.contains(
            "/home/ubuntu/.cmux/bin/cmuxd-remote/0.64.16/linux-arm64/cmuxd-remote.tmp-"
        ) == true)
    }

    private static func makeCoordinator(
        destination: String,
        runner: RecordingDaemonUploadProcessRunner
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh \(destination)",
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )

        return RemoteSessionCoordinator(
            host: DaemonUploadNoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: DaemonUploadUnusedRemoteProxyBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: DaemonUploadNoopReachabilityProbe(),
            relayCommandRewriter: DaemonUploadPassthroughRelayCommandRewriter(),
            buildInfo: DaemonUploadStubBuildInfo(),
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

private final class RecordingDaemonUploadProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    // `run` is a synchronous protocol method; this lock only protects test observations.
    private let lock = NSLock()
    private var recordedRequests: [RemoteProcessRequest] = []

    var requests: [RemoteProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        if request.executable == "/usr/bin/scp" {
            return RemoteCommandResult(status: 1, stdout: "", stderr: "scp should not be used for slash aliases")
        }

        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

private struct DaemonUploadNoopRemoteSessionHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

private final class DaemonUploadUnusedRemoteProxyBroker: RemoteProxyBrokering, @unchecked Sendable {
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        fatalError("Daemon upload tests do not acquire proxy leases")
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
        fatalError("Daemon upload tests do not start PTY bridges")
    }
}

private struct DaemonUploadNoopReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

private struct DaemonUploadPassthroughRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

private struct DaemonUploadStubBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
