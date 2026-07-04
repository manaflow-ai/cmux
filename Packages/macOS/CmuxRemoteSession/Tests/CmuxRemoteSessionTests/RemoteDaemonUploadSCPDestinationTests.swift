import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote daemon upload scp destination")
struct RemoteDaemonUploadSCPDestinationTests {
    @Test("Daemon bootstrap upload brackets IPv6 scp destinations")
    func daemonBootstrapUploadBracketsIPv6ScpDestination() throws {
        // Regression for https://github.com/manaflow-ai/cmux/issues/4948 (part
        // of https://github.com/manaflow-ai/cmux/issues/6353): `scp local
        // host:path` splits the remote target on the first colon, so a bare IPv6
        // host must be bracketed as `user@[ipv6]:path`.
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-ipv6-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fakeDaemonURL = directoryURL.appendingPathComponent("cmuxd-remote", isDirectory: false)
        try Data("fake daemon".utf8).write(to: fakeDaemonURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDaemonURL.path)

        let runner = CapturingRemoteDaemonUploadProcessRunner()
        let coordinator = makeCoordinator(
            processRunner: runner,
            manifestHomeDirectory: directoryURL,
            environment: [
                "CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD": "1",
                "CMUX_REMOTE_DAEMON_BINARY": fakeDaemonURL.path,
            ]
        )
        defer { coordinator.stop() }

        coordinator.queue.sync {
            _ = try? coordinator.bootstrapDaemonLocked(requiredCapabilities: [])
        }

        let destination = try #require(runner.scpDestination)
        #expect(
            destination.hasPrefix("lawrence@[2001:db8::5]:/home/test/.cmux/bin/cmuxd-remote/"),
            "expected scp to bracket the IPv6 host so the upload reaches the host, got \(destination)"
        )
        #expect(
            !destination.hasPrefix("lawrence@2001:db8::5:"),
            "a bare IPv6 scp destination is misparsed by scp (issue #4948), got \(destination)"
        )
    }

    private func makeCoordinator(
        processRunner: any RemoteSessionProcessRunning,
        manifestHomeDirectory: URL,
        environment: [String: String]
    ) -> RemoteSessionCoordinator {
        RemoteSessionCoordinator(
            host: NoopRemoteDaemonUploadSessionHost(),
            configuration: WorkspaceRemoteConfiguration(
                destination: "lawrence@2001:db8::5",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: "ssh lawrence@2001:db8::5"
            ),
            proxyBroker: UnusedRemoteDaemonUploadProxyBroker(),
            manifestRepository: RemoteDaemonManifestRepository(homeDirectory: manifestHomeDirectory),
            processRunner: processRunner,
            reachabilityProbe: NoopRemoteDaemonUploadReachabilityProbe(),
            relayCommandRewriter: PassthroughRemoteDaemonUploadRelayCommandRewriter(),
            buildInfo: StubRemoteDaemonUploadBuildInfo(),
            environment: environment,
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

// `scpDestination` is mutated only while the test runs the coordinator queue synchronously.
private final class CapturingRemoteDaemonUploadProcessRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    var scpDestination: String?

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.executable == "/usr/bin/ssh" {
            let command = request.arguments.last ?? ""
            if command.contains("uname -s") {
                return RemoteCommandResult(
                    status: 0,
                    stdout: """
                    __CMUX_REMOTE_HOME__=/home/test
                    __CMUX_REMOTE_OS__=Linux
                    __CMUX_REMOTE_ARCH__=x86_64
                    __CMUX_REMOTE_EXISTS__=no
                    """,
                    stderr: ""
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        if request.executable == "/usr/bin/scp" {
            scpDestination = request.arguments.last
            return RemoteCommandResult(
                status: 1,
                stdout: "",
                stderr: "intentional stop after upload destination capture"
            )
        }
        return RemoteCommandResult(status: 1, stdout: "", stderr: "unexpected executable \(request.executable)")
    }
}

private struct NoopRemoteDaemonUploadSessionHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

// This test never mutates proxy-broker state; unreachable methods trap if that changes.
private final class UnusedRemoteDaemonUploadProxyBroker: RemoteProxyBrokering, @unchecked Sendable {
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        fatalError("UnusedRemoteDaemonUploadProxyBroker.acquire is not exercised by this test")
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
        fatalError("UnusedRemoteDaemonUploadProxyBroker.startPTYBridge is not exercised by this test")
    }
}

private struct NoopRemoteDaemonUploadReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

private struct PassthroughRemoteDaemonUploadRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

private struct StubRemoteDaemonUploadBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
