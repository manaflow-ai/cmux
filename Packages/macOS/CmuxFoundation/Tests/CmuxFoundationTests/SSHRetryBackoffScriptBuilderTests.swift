import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

struct SSHRetryBackoffScriptBuilderTests {
    @Test func startupBackoffExitsPromptlyOnSignal() throws {
        try assertSignalInterruptsBackoff(
            context: .startup,
            signalHandler: "cmux_ssh_signal_exit",
            signalStatusVariable: "cmux_ssh_signal_status",
            signalNameVariable: "cmux_ssh_signal_name",
            delayVariable: "cmux_ssh_reconnect_delay"
        )
    }

    @Test func attachBackoffExitsPromptlyOnSignal() throws {
        try assertSignalInterruptsBackoff(
            context: .attach,
            signalHandler: "cmux_ssh_attach_signal_exit",
            signalStatusVariable: "cmux_ssh_attach_signal_status",
            signalNameVariable: "cmux_ssh_attach_signal_name",
            delayVariable: "cmux_ssh_attach_reconnect_delay"
        )
    }

    private func assertSignalInterruptsBackoff(
        context: SSHRetryBackoffContext,
        signalHandler: String,
        signalStatusVariable: String,
        signalNameVariable: String,
        delayVariable: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ssh-shared-backoff-\(UUID().uuidString)", isDirectory: true)
        let fakeSleep = root.appendingPathComponent("sleep")
        let readyMarker = root.appendingPathComponent("ready")
        let backoffPIDFile = root.appendingPathComponent("backoff-pid")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        #!/bin/sh
        printf '%s\n' "$$" > "$CMUX_TEST_BACKOFF_PID"
        : > "$CMUX_TEST_BACKOFF_READY"
        exec /bin/sleep "$1"
        """.write(to: fakeSleep, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        let builder = SSHRetryBackoffScriptBuilder(context: context)
        let script = ([
            "\(delayVariable)=30",
        ] + builder.stateInitializationLines + [
            "\(signalHandler)() { \(signalStatusVariable)=\"$1\"; \(signalNameVariable)=\"$2\"; if false; then :; \(builder.signalHandlerBranches) fi; trap - HUP INT TERM; exit \"$\(signalStatusVariable)\"; }",
            "trap '\(signalHandler) 129 HUP' HUP",
            "trap '\(signalHandler) 130 INT' INT",
            "trap '\(signalHandler) 143 TERM' TERM",
        ] + builder.waitLines + [
            "exit 0",
        ]).joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(root.path):/usr/bin:/bin",
            "CMUX_TEST_BACKOFF_PID": backoffPIDFile.path,
            "CMUX_TEST_BACKOFF_READY": readyMarker.path,
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var backoffPID: Int32?
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if let backoffPID {
                Darwin.kill(backoffPID, SIGKILL)
            }
        }

        try process.run()
        let readyDeadline = Date.now.addingTimeInterval(3)
        while !fileManager.fileExists(atPath: readyMarker.path),
              process.isRunning,
              Date.now < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(fileManager.fileExists(atPath: readyMarker.path))
        let parsedBackoffPID = try #require(Int32(
            String(contentsOf: backoffPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        backoffPID = parsedBackoffPID

        Darwin.kill(process.processIdentifier, SIGINT)
        let exitDeadline = Date.now.addingTimeInterval(1)
        while process.isRunning, Date.now < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let exitedPromptly = !process.isRunning
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(exitedPromptly)
        #expect(process.terminationStatus == 130)
    }
}
