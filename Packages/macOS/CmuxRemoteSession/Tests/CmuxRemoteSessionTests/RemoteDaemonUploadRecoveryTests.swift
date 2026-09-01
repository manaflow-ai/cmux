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
        ).filter {
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory != true else {
                return false
            }
            return $0.lastPathComponent.contains(".tmp-") && $0.pathExtension != "pid"
        }
        let temporaryFile = try #require(temporaryFiles.first)
        #expect(temporaryFiles.count == 1)
        #expect(try Data(contentsOf: temporaryFile) == payload)
        let markerPath = "\(temporaryFile.path).pid"
        #expect(fileManager.fileExists(atPath: markerPath))

        let finalURL = remoteDirectory.appendingPathComponent("cmuxd-remote")
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let finalize = RemoteSessionCoordinator.remoteDaemonFinalizeScript(
            remoteTempPath: temporaryFile.path,
            remotePath: finalURL.path,
            expectedByteCount: Int64(payload.count),
            expectedSHA256: hash
        )
        #expect(try Self.runShell(finalize) == 0)
        #expect(try Data(contentsOf: finalURL) == payload)
        #expect(!fileManager.fileExists(atPath: markerPath))
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
        let remotePath = location.absolutePath

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
        // Recovery is age-based. It must not probe or signal the marker PID,
        // because a reused PID could belong to an unrelated live process.
        #expect(cleanupRequest.arguments.last?.contains("kill -0") == false)
        #expect(cleanupRequest.arguments.last?.contains("kill \"$cmux_current_pid\"") == false)
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
        let lockPath = "\(pidPath).lock"
        try fileManager.createDirectory(atPath: lockPath, withIntermediateDirectories: false)

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
        #expect(fileManager.fileExists(atPath: lockPath))
        try fileManager.removeItem(atPath: lockPath)
        try Self.ageFile(atPath: pidPath)
        try Self.ageFile(atPath: temporaryPath)
        let agedLiveCleanup = Process()
        agedLiveCleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        agedLiveCleanup.arguments = ["-c", RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath)]
        agedLiveCleanup.standardInput = FileHandle.nullDevice
        agedLiveCleanup.standardOutput = FileHandle.nullDevice
        agedLiveCleanup.standardError = FileHandle.nullDevice
        try agedLiveCleanup.run()
        agedLiveCleanup.waitUntilExit()
        #expect(agedLiveCleanup.terminationStatus == 0)
        #expect(writer.isRunning)
        #expect(!fileManager.fileExists(atPath: temporaryPath))
        #expect(!fileManager.fileExists(atPath: pidPath))
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

    @Test("Remote cleanup keeps fresh dead and malformed markers until aged")
    func cleanupScriptRequiresAgedMarkers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-cleanup-age-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let remotePath = root.appendingPathComponent("quoted path's/cmuxd-remote").path
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: remotePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let deadPath = "\(remotePath).tmp-dead"
        let malformedPath = "\(remotePath).tmp-malformed"
        try Data("dead".utf8).write(to: URL(fileURLWithPath: deadPath))
        try Data("999999\n".utf8).write(to: URL(fileURLWithPath: "\(deadPath).pid"))
        try Data("malformed".utf8).write(to: URL(fileURLWithPath: malformedPath))
        try Data("not-a-pid\n".utf8).write(to: URL(fileURLWithPath: "\(malformedPath).pid"))

        #expect(try Self.runShell(RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath)) == 0)
        #expect(fileManager.fileExists(atPath: deadPath))
        #expect(fileManager.fileExists(atPath: malformedPath))

        try Self.ageFile(atPath: deadPath)
        try Self.ageFile(atPath: "\(deadPath).pid")
        try Self.ageFile(atPath: malformedPath)
        try Self.ageFile(atPath: "\(malformedPath).pid")
        #expect(try Self.runShell(RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath)) == 0)
        #expect(!fileManager.fileExists(atPath: deadPath))
        #expect(!fileManager.fileExists(atPath: malformedPath))
    }

    @Test("Remote cleanup preserves files when the age probe is unavailable")
    func cleanupScriptFailsClosedWithoutAgeProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-cleanup-no-mmin-\(UUID().uuidString)", isDirectory: true
        )
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let remotePath = root.appendingPathComponent("cmuxd-remote").path
        let temporaryPath = "\(remotePath).tmp-live"
        let markerPath = "\(temporaryPath).pid"
        try Data("active".utf8).write(to: URL(fileURLWithPath: temporaryPath))
        try Data("not-a-pid\n".utf8).write(to: URL(fileURLWithPath: markerPath))
        let fakeFind = bin.appendingPathComponent("find")
        try "#!/bin/sh\nexit 127\n".write(to: fakeFind, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFind.path)

        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(remotePath: remotePath),
        ]
        cleanup.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        cleanup.standardInput = FileHandle.nullDevice
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        try cleanup.run()
        cleanup.waitUntilExit()

        // An unsupported age predicate must preserve the marker for a later
        // compatible cleanup pass.
        #expect(cleanup.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: temporaryPath))
        #expect(fileManager.fileExists(atPath: markerPath))
    }

    @Test("Remote cleanup kills only the explicitly failed writer")
    func cleanupScriptScopesCurrentWriter() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-cleanup-scope-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let remotePath = root
            .appendingPathComponent("remote path's", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
            .path
        let remoteDirectory = URL(fileURLWithPath: remotePath).deletingLastPathComponent()
        try fileManager.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)

        let currentPath = "\(remotePath).tmp-current"
        let otherPath = "\(remotePath).tmp-other"
        let currentPIDPath = "\(currentPath).pid"
        let otherPIDPath = "\(otherPath).pid"
        try Data("current".utf8).write(to: URL(fileURLWithPath: currentPath))
        try Data("other".utf8).write(to: URL(fileURLWithPath: otherPath))

        let currentWriter = Process()
        currentWriter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        currentWriter.arguments = ["30"]
        currentWriter.standardInput = FileHandle.nullDevice
        currentWriter.standardOutput = FileHandle.nullDevice
        currentWriter.standardError = FileHandle.nullDevice
        try currentWriter.run()
        defer {
            if currentWriter.isRunning {
                currentWriter.terminate()
                currentWriter.waitUntilExit()
            }
        }

        let otherWriter = Process()
        otherWriter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        otherWriter.arguments = ["30"]
        otherWriter.standardInput = FileHandle.nullDevice
        otherWriter.standardOutput = FileHandle.nullDevice
        otherWriter.standardError = FileHandle.nullDevice
        try otherWriter.run()
        defer {
            if otherWriter.isRunning {
                otherWriter.terminate()
                otherWriter.waitUntilExit()
            }
        }

        try Data("\(currentWriter.processIdentifier)\n".utf8)
            .write(to: URL(fileURLWithPath: currentPIDPath))
        try Data("\(otherWriter.processIdentifier)\n".utf8)
            .write(to: URL(fileURLWithPath: otherPIDPath))

        let currentCleanup = RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(
            remotePath: remotePath,
            currentTemporaryPath: currentPath
        )
        #expect(try Self.runShell(currentCleanup) == 0)
        #expect(currentWriter.isRunning)
        #expect(!fileManager.fileExists(atPath: currentPath))
        #expect(!fileManager.fileExists(atPath: currentPIDPath))
        #expect(otherWriter.isRunning)
        #expect(fileManager.fileExists(atPath: otherPath))
        #expect(fileManager.fileExists(atPath: otherPIDPath))

        otherWriter.terminate()
        otherWriter.waitUntilExit()
        try Self.ageFile(atPath: otherPath)
        try Self.ageFile(atPath: otherPIDPath)
        let staleCleanup = RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(
            remotePath: remotePath
        )
        #expect(try Self.runShell(staleCleanup) == 0)
        #expect(!fileManager.fileExists(atPath: otherPath))
        #expect(!fileManager.fileExists(atPath: otherPIDPath))
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

    private static func ageFile(atPath path: String) throws {
        let oldDate = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: path
        )
    }
}
