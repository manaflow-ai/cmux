import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import CryptoKit
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
            switch Self.uploadStep(for: request) {
            case .createDirectory, .upload, .finalize:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .cleanup, .unknown:
                return Self.unexpectedRequestResult(request)
            }
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
        #expect(requests.map(Self.uploadStep) == [.createDirectory, .upload, .finalize])
        #expect(requests.allSatisfy { $0.executable == "/usr/bin/ssh" })
        let createDirectoryRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .createDirectory
            }
        )
        #expect(createDirectoryRequest.arguments.last?.contains(location.directory) == true)
        let uploadRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .upload
            }
        )
        #expect(uploadRequest.stdinFile == localBinary)
        let finalizeRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .finalize
            }
        )
        #expect(finalizeRequest.arguments.last?.contains(location.absolutePath) == true)
    }

    @Test("Upload reports SSH exec failures with a safe transfer error")
    func uploadReportsExecFailureDetail() throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("fake daemon".utf8).write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let runner = RecordingProcessRunner { request in
            switch Self.uploadStep(for: request) {
            case .createDirectory, .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .upload:
                return RemoteCommandResult(
                    status: 1,
                    stdout: "",
                    stderr: "cat: remote path: Permission denied"
                )
            case .finalize, .unknown:
                return Self.unexpectedRequestResult(request)
            }
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
                nsError.localizedDescription == "failed to upload remote daemon"
            )
        }

        let requests = runner.requests
        #expect(requests.map(Self.uploadStep) == [.createDirectory, .upload, .cleanup])
        let uploadRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .upload
            }
        )
        let cleanupRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .cleanup
            }
        )
        let temporaryPathMarker = try #require(
            Self.temporaryPathMarker(in: uploadRequest.arguments.last)
        )
        #expect(cleanupRequest.arguments.last?.contains(temporaryPathMarker) == true)
        #expect(cleanupRequest.arguments.last?.contains(location.absolutePath) == true)
    }

    @Test("Finalization failure cleans the temporary upload and reports a safe install error")
    func finalizationFailureCleansTemporaryUpload() throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("fake daemon".utf8).write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let runner = RecordingProcessRunner { request in
            switch Self.uploadStep(for: request) {
            case .createDirectory, .upload, .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .finalize:
                return RemoteCommandResult(
                    status: 1,
                    stdout: "",
                    stderr: "chmod: remote helper: Operation not permitted"
                )
            case .unknown:
                return Self.unexpectedRequestResult(request)
            }
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
            Issue.record("Expected remote daemon finalization to fail")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 32)
            #expect(
                nsError.localizedDescription == "failed to install remote daemon"
            )
        }

        let requests = runner.requests
        #expect(requests.map(Self.uploadStep) == [.createDirectory, .upload, .finalize, .cleanup])
        let uploadRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .upload
            }
        )
        let cleanupRequest = try #require(
            requests.first { request in
                Self.uploadStep(for: request) == .cleanup
            }
        )
        let temporaryPathMarker = try #require(
            Self.temporaryPathMarker(in: uploadRequest.arguments.last)
        )
        #expect(cleanupRequest.arguments.last?.contains(temporaryPathMarker) == true)
        #expect(cleanupRequest.arguments.last?.contains(location.absolutePath) == true)
    }

    @Test("A truncated remote payload is rejected before daemon promotion")
    func truncatedPayloadIsRejectedBeforePromotion() throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-integrity-\(UUID().uuidString)",
            isDirectory: false
        )
        let payload = Data("verified daemon payload".utf8)
        try payload.write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let expectedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let runner = RecordingProcessRunner { request in
            switch Self.uploadStep(for: request) {
            case .createDirectory, .upload, .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .finalize:
                return RemoteCommandResult(
                    status: 74,
                    stdout: "",
                    stderr: "cmux daemon verification failed: size mismatch expected=23 actual=0"
                )
            case .unknown:
                return Self.unexpectedRequestResult(request)
            }
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
            Issue.record("Expected remote integrity verification to reject the truncated payload")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 33)
            #expect(nsError.localizedDescription == "remote daemon integrity verification failed")
            #expect(!nsError.localizedDescription.contains("size mismatch"))
        }

        let finalizeRequest = try #require(
            runner.requests.first { Self.uploadStep(for: $0) == .finalize }
        )
        let finalizeCommand = finalizeRequest.arguments.last ?? ""
        #expect(finalizeCommand.contains("wc -c"))
        #expect(finalizeCommand.contains("sha256sum"))
        #expect(finalizeCommand.contains(expectedHash))
        #expect(finalizeCommand.contains("mv"))
        #expect(runner.requests.map(Self.uploadStep) == [.createDirectory, .upload, .finalize, .cleanup])
    }

    @Test("Bootstrap repairs an executable install whose probe reports zero bytes")
    func bootstrapRepairsZeroByteInstall() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-bootstrap-repair-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let payload = Data("cached daemon payload".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifestJSON = """
        {"schemaVersion":1,"appVersion":"test-version","releaseTag":"test","releaseURL":"https://example.invalid","checksumsAssetName":"checksums","checksumsURL":"https://example.invalid/checksums","entries":[{"goOS":"linux","goArch":"amd64","assetName":"cmuxd-remote-linux-amd64","downloadURL":"https://example.invalid/cmuxd-remote","sha256":"\(hash)"}]}
        """
        let manifest = try #require(
            WorkspaceRemoteDaemonManifest(
                infoDictionary: [WorkspaceRemoteDaemonManifest.infoDictionaryKey: manifestJSON]
            )
        )
        let repository = RemoteDaemonManifestRepository(homeDirectory: home)
        let cachedURL = try repository.cachedBinaryURL(
            version: "test-version",
            goOS: "linux",
            goArch: "amd64"
        )
        try fileManager.createDirectory(
            at: cachedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: cachedURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedURL.path)

        let runner = RecordingProcessRunner { request in
            let command = request.arguments.last ?? ""
            if command.contains(RemoteSessionCoordinator.remotePlatformProbeHomeMarker) {
                return RemoteCommandResult(
                    status: 0,
                    stdout: """
                    \(RemoteSessionCoordinator.remotePlatformProbeHomeMarker)\(home.path)
                    \(RemoteSessionCoordinator.remotePlatformProbeOSMarker)Linux
                    \(RemoteSessionCoordinator.remotePlatformProbeArchMarker)x86_64
                    \(RemoteSessionCoordinator.remotePlatformProbeExistsMarker)yes
                    \(RemoteSessionCoordinator.remotePlatformProbeSizeMarker)0
                    """,
                    stderr: ""
                )
            }
            switch Self.uploadStep(for: request) {
            case .createDirectory, .upload, .finalize:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .unknown:
                if command.contains("hello") {
                    return RemoteCommandResult(
                        status: 0,
                        stdout: #"{"ok":true,"result":{"name":"cmuxd-remote","version":"test-version","capabilities":[]}}"#,
                        stderr: ""
                    )
                }
                return Self.unexpectedRequestResult(request)
            }
        }
        let configuration = WorkspaceRemoteConfiguration(
            destination: "test@repair.example",
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
        let coordinator = RemoteSessionCoordinator(
            host: NoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: repository,
            processRunner: runner,
            reachabilityProbe: SSHOverrideNoopReachabilityProbe(),
            relayCommandRewriter: SSHOverridePassthroughRelayCommandRewriter(),
            buildInfo: ManifestBuildInfo(version: "test-version", manifest: manifest),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@",
                reverseRelayUnavailableRetrying: "",
                reverseRelayPortUnavailableRetrying: "",
                controlMasterOwnershipUnavailable: ""
            )
        )
        defer { coordinator.stop() }

        let hello = try coordinator.queue.sync {
            try coordinator.bootstrapDaemonLocked(requiredCapabilities: [])
        }
        #expect(hello.version == "test-version")
        #expect(runner.requests.contains { Self.uploadStep(for: $0) == .upload })
        #expect(runner.requests.contains { Self.uploadStep(for: $0) == .finalize })
    }

    @Test("Upload process failures do not expose arbitrary local error text")
    func uploadProcessFailureSanitizesLocalDetail() throws {
        try assertProcessFailureIsSanitized(
            at: .upload,
            expectedCode: 31,
            expectedDescription: "failed to upload remote daemon"
        )
    }

    @Test("Directory process failures do not expose arbitrary local error text")
    func directoryProcessFailureSanitizesLocalDetail() throws {
        try assertProcessFailureIsSanitized(
            at: .createDirectory,
            expectedCode: 30,
            expectedDescription: "failed to create remote daemon directory"
        )
    }

    @Test("Finalization process failures do not expose arbitrary local error text")
    func finalizationProcessFailureSanitizesLocalDetail() throws {
        try assertProcessFailureIsSanitized(
            at: .finalize,
            expectedCode: 32,
            expectedDescription: "failed to install remote daemon"
        )
    }

    private func assertProcessFailureIsSanitized(
        at failingStep: RemoteDaemonUploadStep,
        expectedCode: Int,
        expectedDescription: String
    ) throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data("fake daemon".utf8).write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let privateDetail = "sensitive local path /Users/example/private/key"
        let runner = RecordingProcessRunner { request in
            let step = Self.uploadStep(for: request)
            if step == failingStep {
                throw NSError(domain: "test.local.process", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: privateDetail,
                ])
            }
            switch step {
            case .createDirectory, .upload, .finalize, .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .unknown:
                return Self.unexpectedRequestResult(request)
            }
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
            Issue.record("Expected the injected process failure to propagate")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == expectedCode)
            #expect(nsError.localizedDescription == expectedDescription)
            #expect(!nsError.localizedDescription.contains(privateDetail))
        }

        let expectedSteps: [RemoteDaemonUploadStep]
        switch failingStep {
        case .createDirectory:
            expectedSteps = [.createDirectory]
        case .upload:
            expectedSteps = [.createDirectory, .upload, .cleanup]
        case .finalize:
            expectedSteps = [.createDirectory, .upload, .finalize, .cleanup]
        case .cleanup, .unknown:
            Issue.record("Unsupported process-failure test step: \(failingStep)")
            return
        }
        #expect(runner.requests.map(Self.uploadStep) == expectedSteps)
    }

    private static func uploadStep(for request: RemoteProcessRequest) -> RemoteDaemonUploadStep {
        guard request.executable == "/usr/bin/ssh",
              let command = request.arguments.last else {
            return .unknown
        }
        if command.contains("mkdir -p ") {
            return .createDirectory
        }
        if command.contains("exec 4> ") || command.contains("cat <&3 >&4") {
            return .upload
        }
        if command.contains("chmod 755 "), command.contains("mv ") {
            return .finalize
        }
        if command.contains("rm -f -- ") {
            return .cleanup
        }
        return .unknown
    }

    private static func temporaryPathMarker(in command: String?) -> String? {
        guard let command,
              let markerRange = command.range(of: ".tmp-") else {
            return nil
        }
        let marker = command[markerRange.lowerBound...].prefix(13)
        guard marker.count == 13 else { return nil }
        return String(marker)
    }

    private static func unexpectedRequestResult(_ request: RemoteProcessRequest) -> RemoteCommandResult {
        RemoteCommandResult(
            status: 97,
            stdout: "",
            stderr: "unexpected request: \(request.executable) \(request.arguments.last ?? "<missing>")"
        )
    }

    func makeCoordinator(
        runner: RecordingProcessRunner,
        sshOptions: [String] = []
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "test@sftp-disabled.example",
            port: 2222,
            identityFile: "/tmp/cmux-test-identity",
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
            manifestRepository: RemoteDaemonManifestRepository(homeDirectory: FileManager.default.temporaryDirectory),
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
                suspendedDetailFormat: "%@",
                reverseRelayUnavailableRetrying: "",
                reverseRelayPortUnavailableRetrying: "",
                controlMasterOwnershipUnavailable: ""
            )
        )
    }
}

private struct ManifestBuildInfo: RemoteSessionBuildInfoProviding {
    let version: String
    let manifest: WorkspaceRemoteDaemonManifest

    func appVersion() -> String? { version }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { manifest }
    func executableDirectoryURL() -> URL? { nil }
}
