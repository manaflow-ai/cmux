import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7130
// ("Support OrbStack machines over ssh").
//
// OrbStack machines are reached through OrbStack's built-in SSH server, which
// is a custom Go implementation that does not offer the OpenSSH `sftp`
// subsystem. Modern `scp` (OpenSSH 9+, the macOS default) transfers over SFTP,
// so the daemon-binary upload step of the remote bootstrap fails with
// "subsystem request failed on channel 0" even though the plain exec channel
// (used for the platform probe, the interactive terminal, and the daemon
// hello) works fine. The bootstrap then never reaches `.connected`, so the
// file-tree panel is gated off and shows "SSH files unavailable".
//
// The coordinator must fall back to streaming the binary over the exec channel
// (`sh -c 'cat > tmp'`) when scp fails, which needs only a shell — the same
// capability the rest of the bootstrap already relies on.
@Suite("Remote daemon binary upload SFTP fallback")
struct RemoteDaemonUploadFallbackTests {
    @Test("Falls back to an exec-channel upload when scp's SFTP subsystem is unavailable")
    func fallsBackToExecChannelWhenScpFails() throws {
        let runner = ScriptedUploadRunner(
            scpResult: RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr: "subsystem request failed on channel 0\nscp: Connection closed"
            )
        )
        let coordinator = Self.makeCoordinator(runner: runner)

        let localBinary = try Self.makeTemporaryBinary()
        defer { try? FileManager.default.removeItem(at: localBinary) }
        let location = RemoteDaemonInstallLocation(
            relativePath: ".cmux/bin/cmuxd-remote/dev/linux-arm64/cmuxd-remote",
            absolutePath: "/home/seepine/.cmux/bin/cmuxd-remote/dev/linux-arm64/cmuxd-remote"
        )

        // Without the fallback the coordinator surfaces the scp failure as a
        // bootstrap error (cmux.remote.daemon code 31) and the connection never
        // reaches `.connected`. With the fallback it uploads over the exec
        // channel and returns normally.
        try coordinator.queue.sync {
            try coordinator.uploadRemoteDaemonBinaryLocked(localBinary: localBinary, location: location)
        }

        // The fallback must actually reach the remote over the exec channel via
        // `cat`, not silently no-op.
        #expect(runner.sawExecChannelCatUpload)
        coordinator.stop()
    }

    // MARK: - Harness

    private static func makeTemporaryBinary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-daemon-upload-\(UUID().uuidString).bin", isDirectory: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        return url
    }

    private static func makeCoordinator(runner: ScriptedUploadRunner) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "seepine@debian@orb",
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
            host: UploadNoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: UploadUnusedRemoteProxyBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: UploadNoopReachabilityProbe(),
            relayCommandRewriter: UploadPassthroughRelayCommandRewriter(),
            buildInfo: UploadStubBuildInfo(),
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

/// Fails every `scp` invocation the way OrbStack's SFTP-less server does, lets
/// every `ssh` exec succeed, and records whether the binary was streamed to the
/// remote over an exec-channel `cat` upload.
private final class ScriptedUploadRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let scpResult: RemoteCommandResult
    private var _sawExecChannelCatUpload = false

    init(scpResult: RemoteCommandResult) {
        self.scpResult = scpResult
    }

    var sawExecChannelCatUpload: Bool { lock.withLock { _sawExecChannelCatUpload } }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.executable.hasSuffix("/scp") {
            return scpResult
        }
        // ssh: the remote command is always the trailing argument.
        let remoteCommand = request.arguments.last ?? ""
        if remoteCommand.contains("cat >") {
            lock.withLock { _sawExecChannelCatUpload = true }
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

private struct UploadNoopRemoteSessionHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

private final class UploadUnusedRemoteProxyBroker: RemoteProxyBrokering, @unchecked Sendable {
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        fatalError("UploadUnusedRemoteProxyBroker.acquire is not exercised by the upload fallback test")
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
        fatalError("UploadUnusedRemoteProxyBroker.startPTYBridge is not exercised by the upload fallback test")
    }
}

private struct UploadNoopReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

private struct UploadPassthroughRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

private struct UploadStubBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
