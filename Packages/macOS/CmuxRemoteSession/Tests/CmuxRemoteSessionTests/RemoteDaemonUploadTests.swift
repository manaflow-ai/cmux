import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote daemon upload")
struct RemoteDaemonUploadTests {
    @Test("Upload succeeds through SSH exec when SCP's SFTP transport is unavailable")
    func uploadSucceedsWithoutSFTP() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let localBinary = root.appendingPathComponent("cmuxd-remote", isDirectory: false)
        try Data("fake daemon".utf8).write(to: localBinary)

        let runner = RecordingProcessRunner { request in
            if request.executable == "/usr/bin/scp" {
                return RemoteCommandResult(
                    status: 1,
                    stdout: "",
                    stderr: "subsystem request failed on channel 0"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let coordinator = makeCoordinator(runner: runner)
        defer { coordinator.stop() }
        let location = RemoteDaemonInstallLocation(
            relativePath: ".cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote",
            absolutePath: "/home/test/.cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote"
        )

        try coordinator.queue.sync {
            try coordinator.uploadRemoteDaemonBinaryLocked(
                localBinary: localBinary,
                location: location
            )
        }

        let requests = runner.requests
        #expect(requests.contains { $0.executable == "/usr/bin/scp" } == false)
        let uploadRequest = try #require(
            requests.first { request in
                request.executable == "/usr/bin/ssh" &&
                    request.arguments.last?.contains("cat >") == true
            }
        )
        #expect(uploadRequest.stdinFile == localBinary)
    }

    @Test("Upload reports SSH exec failures with their remote detail")
    func uploadReportsExecFailureDetail() throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("fake daemon".utf8).write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let runner = RecordingProcessRunner { request in
            if request.executable == "/usr/bin/ssh",
               request.arguments.last?.contains("cat >") == true {
                return RemoteCommandResult(
                    status: 1,
                    stdout: "",
                    stderr: "cat: remote path: Permission denied"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let coordinator = makeCoordinator(runner: runner)
        defer { coordinator.stop() }
        let location = RemoteDaemonInstallLocation(
            relativePath: ".cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote",
            absolutePath: "/home/test/.cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote"
        )

        do {
            try coordinator.queue.sync {
                try coordinator.uploadRemoteDaemonBinaryLocked(
                    localBinary: localBinary,
                    location: location
                )
            }
            Issue.record("Expected SSH exec upload to fail")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 31)
            #expect(
                nsError.localizedDescription ==
                    "failed to upload cmuxd-remote: cat: remote path: Permission denied"
            )
        }
    }

    private func makeCoordinator(runner: RecordingProcessRunner) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "test@sftp-disabled.example",
            port: 2222,
            identityFile: "/tmp/cmux-test-identity",
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
            host: NoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: UnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(homeDirectory: FileManager.default.temporaryDirectory),
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
