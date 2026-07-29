import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

struct SSHPTYAttachRetryScriptBuilderTests {
    @Test func retriesInitialAuthenticationBeforeAttaching() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: true
        )
        let script = ([
            "cmux_ssh_attach_auth_pid=",
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
            "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 7; }",
            "cmux_ssh_attach_foreground_auth() {",
            "  count=$(test -f \"$CMUX_TEST_LOG\" && grep -c '^auth$' \"$CMUX_TEST_LOG\" 2>/dev/null || printf 0)",
            "  printf '%s\\n' auth >> \"$CMUX_TEST_LOG\"",
            "  if [ \"$count\" -eq 0 ]; then return 254; fi",
            "  return 0",
            "}",
        ] + retryLines).joined(separator: "\n")

        let result = try run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "2",
            ]
        )

        #expect(result.status == 7)
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "auth\nsleep:2\nauth\nattach\n")
    }

    @Test func retriesAttachWithoutRequiringAuthentication() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-only-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
            "cmux_test_attach() {",
            """
            count=$(test -f "$CMUX_TEST_LOG" && grep -c '^attach$' "$CMUX_TEST_LOG" 2>/dev/null || printf 0)
            printf '%s\\n' attach >> "$CMUX_TEST_LOG"
            if [ "$count" -eq 0 ]; then return 255; fi
            return 253
            """,
            "}",
        ] + retryLines).joined(separator: "\n")

        let result = try run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "2",
            ]
        )

        #expect(result.status == 253)
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "attach\nsleep:2\nattach\n")
    }

    @Test(arguments: [
        (SIGHUP, Int32(129), false),
        (SIGINT, Int32(130), false),
        (SIGTERM, Int32(143), false),
        (SIGHUP, Int32(129), true),
        (SIGINT, Int32(130), true),
        (SIGTERM, Int32(143), true),
    ])
    func signalInterruptsReconnectBackoffPromptly(
        signal: Int32,
        expectedStatus: Int32,
        reauthenticates: Bool
    ) throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-backoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: reauthenticates
        )
        let script = ([
            "cmux_ssh_attach_active_child_pid=",
            "cmux_ssh_attach_active_child_launching=0",
            "cmux_ssh_attach_signal_exit() {",
            "  cmux_ssh_attach_signal_status=\"$1\"",
            "  cmux_ssh_attach_signal_name=\"$2\"",
            "  if [ -n \"${cmux_ssh_attach_active_child_pid:-}\" ]; then",
            "    /bin/kill -\"$cmux_ssh_attach_signal_name\" \"$cmux_ssh_attach_active_child_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_attach_active_child_pid\" 2>/dev/null || true",
            "    cmux_ssh_attach_active_child_pid=",
            "  elif [ \"${cmux_ssh_attach_active_child_launching:-0}\" = 1 ]; then",
            "    cmux_ssh_attach_pending_signal=\"$cmux_ssh_attach_signal_status\"",
            "    cmux_ssh_attach_pending_signal_name=\"$cmux_ssh_attach_signal_name\"",
            "    return",
            "  fi",
            "  trap - HUP INT TERM",
            "  exit \"$cmux_ssh_attach_signal_status\"",
            "}",
            "trap 'cmux_ssh_attach_signal_exit 129 HUP' HUP",
            "trap 'cmux_ssh_attach_signal_exit 130 INT' INT",
            "trap 'cmux_ssh_attach_signal_exit 143 TERM' TERM",
            "cmux_test_attach() { printf '%s\\n' \"$$\" > \"$CMUX_TEST_BACKOFF_MARKER\"; return 255; }",
            "cmux_ssh_attach_foreground_auth() { printf '%s\\n' \"$$\" > \"$CMUX_TEST_BACKOFF_MARKER\"; return 254; }",
        ] + retryLines).joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_BACKOFF_MARKER": markerURL.path,
            "CMUX_SSH_RECONNECT_DELAY_SECONDS": "30",
            "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
        ]) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: markerURL.path),
              process.isRunning,
              Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        Thread.sleep(forTimeInterval: 0.1)

        let shellPID = try #require(
            Int32(
                String(contentsOf: markerURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        Darwin.kill(shellPID, signal)
        let exitDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let exitedPromptly = !process.isRunning
        if process.isRunning {
            Darwin.kill(shellPID, SIGKILL)
        }
        process.waitUntilExit()

        #expect(exitedPromptly)
        if exitedPromptly {
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == expectedStatus)
        }
    }

    private func run(
        _ script: String,
        environment overrides: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
