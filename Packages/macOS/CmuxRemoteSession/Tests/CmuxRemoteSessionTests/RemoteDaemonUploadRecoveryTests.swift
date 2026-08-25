import CmuxCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteSession

extension RemoteDaemonUploadTests {
    @Test("Background upload reader consumes the SSH stdin stream")
    func backgroundUploadReaderConsumesSSHStdin() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-stdin-\(UUID().uuidString)",
            isDirectory: true
        )
        let remoteDirectory = root.appendingPathComponent("remote", isDirectory: true)
        try fileManager.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let localBinary = root.appendingPathComponent("cmuxd-remote", isDirectory: false)
        let payload = Data(repeating: 0x5A, count: 128 * 1024)
        try payload.write(to: localBinary)

        let runner = RecordingProcessRunner { request in
            // The upload request is the only request with file-backed stdin.
            // Keep the fake endpoint focused on capturing the generated remote
            // command; the command itself is executed below with real stdin.
            if request.stdinFile != nil {
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            }
            switch Self.uploadStep(for: request) {
            case .createDirectory, .finalize:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .cleanup, .upload, .unknown:
                return Self.unexpectedRequestResult(request)
            }
        }
        let coordinator = makeCoordinator(runner: runner)
        defer { coordinator.stop() }
        let location = RemoteDaemonInstallLocation(
            relativePath: "remote/cmuxd-remote",
            absolutePath: remoteDirectory.appendingPathComponent("cmuxd-remote").path
        )

        try coordinator.queue.sync {
            try coordinator.uploadRemoteDaemonBinaryLocked(
                localBinary: localBinary,
                location: location
            )
        }

        let uploadRequest = try #require(
            runner.requests.first { $0.stdinFile == localBinary }
        )
        let uploadCommand = try #require(uploadRequest.arguments.last)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", uploadCommand]
        let inputHandle = try FileHandle(forReadingFrom: localBinary)
        process.standardInput = inputHandle
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? inputHandle.close()

        #expect(process.terminationStatus == 0)
        let temporaryFiles = try fileManager.contentsOfDirectory(
            at: remoteDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".tmp-") }
        let temporaryFile = try #require(temporaryFiles.first)
        #expect(temporaryFiles.count == 1)
        #expect(try Data(contentsOf: temporaryFile) == payload)
        #expect(
            !fileManager.fileExists(atPath: "\(temporaryFile.path).pid"),
            "The upload writer marker must be removed after the stream closes"
        )
    }

    @Test("Finalize script promotes only a byte-and-hash-matching payload")
    func finalizeScriptIsFailClosed() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-finalize-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let tempURL = root.appendingPathComponent("cmuxd-remote.tmp", isDirectory: false)
        let finalURL = root.appendingPathComponent("cmuxd-remote", isDirectory: false)
        let payload = Data("healthy remote daemon".utf8)
        try payload.write(to: tempURL)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let script = RemoteSessionCoordinator.remoteDaemonFinalizeScript(
            remoteTempPath: tempURL.path,
            remotePath: finalURL.path,
            expectedByteCount: Int64(payload.count),
            expectedSHA256: hash
        )

        let success = try Self.runShell(script)
        #expect(success == 0)
        #expect(fileManager.fileExists(atPath: finalURL.path))
        #expect(!fileManager.fileExists(atPath: tempURL.path))
        #expect(try Data(contentsOf: finalURL) == payload)

        try Data("truncated".utf8).write(to: tempURL)
        let mismatch = try Self.runShell(script)
        #expect(mismatch == 74)
        #expect(fileManager.fileExists(atPath: tempURL.path))
    }

    @Test("Bootstrap uploads bypass wedged ControlMasters and scale their deadline with payload size")
    func uploadUsesStandaloneTransportAndScaledDeadline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-timeout-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let smallBinary = root.appendingPathComponent("small-cmuxd-remote", isDirectory: false)
        let largeBinary = root.appendingPathComponent("large-cmuxd-remote", isDirectory: false)
        try Data(repeating: 0x41, count: 64 * 1024).write(to: smallBinary)
        try Data(repeating: 0x42, count: 6 * 1024 * 1024).write(to: largeBinary)

        let sshOptions = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/tmp/cmux-ssh-wedged-test",
        ]
        let smallUpload = try uploadRequestForRecovery(
            localBinary: smallBinary,
            sshOptions: sshOptions
        )
        let largeUpload = try uploadRequestForRecovery(
            localBinary: largeBinary,
            sshOptions: sshOptions
        )

        #expect(Self.consecutive(largeUpload.arguments, "-o", "ControlPath=none"))
        #expect(!largeUpload.arguments.contains("ControlPath=/tmp/cmux-ssh-wedged-test"))
        #expect(Self.consecutive(smallUpload.arguments, "-o", "ControlPath=none"))
        #expect(!smallUpload.arguments.contains("ControlPath=/tmp/cmux-ssh-wedged-test"))
        #expect(largeUpload.timeout > 45)
        #expect(largeUpload.timeout > smallUpload.timeout)
    }

    @Test("Upload timeout reports a safe error and cleans remote temporary files directly")
    func uploadTimeoutSurfacesDetailAndCleansRemoteTemporaryFiles() throws {
        let fileManager = FileManager.default
        let localBinary = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-timeout-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data(repeating: 0x43, count: 6 * 1024 * 1024).write(to: localBinary)
        defer { try? fileManager.removeItem(at: localBinary) }

        let runner = RecordingProcessRunner { request in
            switch Self.uploadStep(for: request) {
            case .createDirectory:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .upload:
                throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "ssh timed out after 222s",
                ])
            case .cleanup:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .finalize, .unknown:
                return Self.unexpectedRequestResult(request)
            }
        }
        let coordinator = makeCoordinator(
            runner: runner,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-wedged-test",
            ]
        )
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
            Issue.record("Expected the timed-out upload to fail")
        } catch {
            #expect(error.localizedDescription == "failed to upload remote daemon")
        }

        let requests = runner.requests
        #expect(requests.map(Self.uploadStep) == [.createDirectory, .upload, .cleanup])
        let uploadRequest = try #require(
            requests.first { Self.uploadStep(for: $0) == .upload }
        )
        let cleanupRequest = try #require(
            requests.first { Self.uploadStep(for: $0) == .cleanup }
        )
        #expect(uploadRequest.arguments.last?.contains("trap") == true)
        #expect(uploadRequest.arguments.last?.contains("kill") == true)
        #expect(uploadRequest.arguments.last?.contains("stall_checks") == true)
        #expect(uploadRequest.arguments.last?.contains("without byte progress") == true)
        #expect(cleanupRequest.arguments.last?.contains("kill -0") == true)
        #expect(cleanupRequest.arguments.last?.contains("rm -f -- \(remotePath).tmp-*") == false)
        #expect(Self.consecutive(cleanupRequest.arguments, "-o", "ControlPath=none"))
        #expect(!cleanupRequest.arguments.contains("ControlPath=/tmp/cmux-ssh-wedged-test"))
    }

    @Test("Remote cleanup preserves live writers and reclaims stale uploads")
    func cleanupScriptPreservesLiveWriters() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let remotePath = root
            .appendingPathComponent("remote path's", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
            .path
        let temporaryPath = "\(remotePath).tmp-stale"
        let pidPath = "\(temporaryPath).pid"
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: remotePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale bytes".utf8).write(to: URL(fileURLWithPath: temporaryPath))

        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sleep")
        writer.arguments = ["30"]
        writer.standardInput = FileHandle.nullDevice
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer {
            if writer.isRunning {
                writer.terminate()
                writer.waitUntilExit()
            }
        }
        try Data("\(writer.processIdentifier)\n".utf8).write(to: URL(fileURLWithPath: pidPath))

        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath),
        ]
        cleanup.standardInput = FileHandle.nullDevice
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        try cleanup.run()
        cleanup.waitUntilExit()

        #expect(cleanup.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: temporaryPath))
        #expect(fileManager.fileExists(atPath: pidPath))
        writer.terminate()
        writer.waitUntilExit()
        #expect(!writer.isRunning)

        let staleCleanup = Process()
        staleCleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        staleCleanup.arguments = ["-c", RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath)]
        staleCleanup.standardInput = FileHandle.nullDevice
        staleCleanup.standardOutput = FileHandle.nullDevice
        staleCleanup.standardError = FileHandle.nullDevice
        try staleCleanup.run()
        staleCleanup.waitUntilExit()
        #expect(staleCleanup.terminationStatus == 0)
        #expect(!fileManager.fileExists(atPath: temporaryPath))
        #expect(!fileManager.fileExists(atPath: pidPath))
    }

    private func uploadRequestForRecovery(
        localBinary: URL,
        sshOptions: [String]
    ) throws -> RemoteProcessRequest {
        let runner = RecordingProcessRunner { request in
            // Model the observed wedged socket: requests carrying the
            // configured path cannot complete. A successful transaction
            // therefore exercises the standalone transport contract.
            if request.arguments.contains("ControlPath=/tmp/cmux-ssh-wedged-test") {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "control master data plane stalled"
                )
            }
            switch Self.uploadStep(for: request) {
            case .createDirectory, .upload, .finalize:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            case .cleanup, .unknown:
                return Self.unexpectedRequestResult(request)
            }
        }
        let coordinator = makeCoordinator(runner: runner, sshOptions: sshOptions)
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
        return try #require(runner.requests.first { Self.uploadStep(for: $0) == .upload })
    }

    private static func uploadStep(for request: RemoteProcessRequest) -> RemoteDaemonUploadStep {
        guard request.executable == "/usr/bin/ssh",
              let command = request.arguments.last else {
            return .unknown
        }
        if command.contains("mkdir -p ") {
            return .createDirectory
        }
        if command.contains("cat > ") || command.contains("cat <&3 > ") {
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

    private static func consecutive(_ args: [String], _ first: String, _ second: String) -> Bool {
        args.indices.dropLast().contains { index in
            args[index] == first && args[index + 1] == second
        }
    }

    private static func unexpectedRequestResult(_ request: RemoteProcessRequest) -> RemoteCommandResult {
        RemoteCommandResult(
            status: 97,
            stdout: "",
            stderr: "unexpected request: \(request.executable) \(request.arguments.last ?? "<missing>")"
        )
    }

    private static func runShell(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
