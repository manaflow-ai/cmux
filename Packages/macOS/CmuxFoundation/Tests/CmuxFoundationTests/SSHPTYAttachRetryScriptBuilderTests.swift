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
