import CmuxRemoteDaemon
import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote daemon upload process")
struct RemoteDaemonUploadProcessTests {
    @Test("Hello execution failures retain the launch phase and safe reason")
    func helloFailureMessageIdentifiesPermissionDenied() {
        let error = NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
            NSLocalizedDescriptionKey: "failed to start remote daemon: Permission denied",
        ])
        let strings = RemoteDaemonStrings(
            missingPersistentPTYCapability: "missing PTY",
            missingRequiredFunctionality: "missing functionality",
            cloudNotificationClearWorkspaceInvalid: "invalid workspace",
            cloudNotificationClearWorkspaceDenied: "denied workspace",
            cloudNotificationClearSurfaceInvalid: "invalid surface"
        )

        #expect(
            RemoteSessionCoordinator.userFacingRemoteDaemonBootstrapErrorMessage(
                error,
                strings: strings
            ) == "Remote daemon launch failed: Permission denied"
        )
    }

    @Test("Upload closes inherited writer descriptors before promotion")
    func uploadDoesNotLeavePromotedBinaryBusy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-daemon-upload-exec-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let localBinary = root.appendingPathComponent("cmuxd-remote", isDirectory: false)
        let source = root.appendingPathComponent("cmuxd-remote.c", isDirectory: false)
        try "#include <stdio.h>\nint main(int argc, char **argv) { puts(argv[1]); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", localBinary.path]
        compiler.standardInput = FileHandle.nullDevice
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        let localData = try Data(contentsOf: localBinary)
        try localData.write(to: localBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localBinary.path)

        let runner = RecordingProcessRunner { _ in
            RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let coordinator = RemoteDaemonUploadTests().makeCoordinator(runner: runner)
        defer { coordinator.stop() }
        let finalURL = root.appendingPathComponent("cmuxd-remote", isDirectory: false)
        let location = RemoteDaemonInstallLocation(
            relativePath: ".cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote",
            absolutePath: finalURL.path
        )

        try coordinator.queue.sync {
            try coordinator.uploadRemoteDaemonBinaryLocked(
                localBinary: localBinary,
                location: location
            )
        }
        let uploadRequest = try #require(
            runner.requests.first { $0.arguments.last?.contains("cat <&3 >&4") == true }
        )
        let uploadCommand = try #require(uploadRequest.arguments.last)

        let uploadInput = Pipe()
        let uploadProcess = Process()
        uploadProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        uploadProcess.arguments = ["-c", uploadCommand]
        uploadProcess.standardInput = uploadInput
        uploadProcess.standardOutput = FileHandle.nullDevice
        uploadProcess.standardError = FileHandle.nullDevice
        try uploadProcess.run()
        try uploadInput.fileHandleForWriting.write(contentsOf: localData)
        try uploadInput.fileHandleForWriting.close()
        uploadProcess.waitUntilExit()
        #expect(uploadProcess.terminationStatus == 0)
        let temporaryURL = try #require(
            fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first {
                    $0.lastPathComponent.contains(".tmp-") &&
                        !$0.lastPathComponent.hasSuffix(".pid") &&
                        !$0.lastPathComponent.hasSuffix(".pid.lock")
                }
        )
        let temporaryPath = temporaryURL.path

        let digest = SHA256.hash(data: localData)
            .map { String(format: "%02x", $0) }
            .joined()
        let finalize = RemoteSessionCoordinator.remoteDaemonFinalizeScript(
            remoteTempPath: temporaryPath,
            remotePath: finalURL.path,
            expectedByteCount: Int64(localData.count),
            expectedSHA256: digest
        )
        let finalizeProcess = Process()
        finalizeProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        finalizeProcess.arguments = ["-c", finalize]
        finalizeProcess.standardInput = FileHandle.nullDevice
        finalizeProcess.standardOutput = FileHandle.nullDevice
        finalizeProcess.standardError = FileHandle.nullDevice
        try finalizeProcess.run()
        finalizeProcess.waitUntilExit()
        #expect(finalizeProcess.terminationStatus == 0)

        let promoted = Process()
        let promotedOutput = Pipe()
        promoted.executableURL = finalURL
        promoted.arguments = ["cmux-upload-text-file-busy"]
        promoted.standardInput = FileHandle.nullDevice
        promoted.standardOutput = promotedOutput
        promoted.standardError = FileHandle.nullDevice
        try promoted.run()
        promoted.waitUntilExit()
        #expect(promoted.terminationStatus == 0)
        #expect(
            String(data: promotedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ==
                "cmux-upload-text-file-busy\n"
        )
    }

}
