import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

struct SSHPTYAttachRetryScriptBuilderTests {
    @Test func defaultReconnectPolicyIsFinite() {
        let script = SSHPTYAttachRetryScriptBuilder()
            .lines(command: "cmux_test_attach", reauthenticates: false)
            .joined(separator: "\n")

        #expect(script.contains("cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\""))
        #expect(!script.contains("cmux_ssh_attach_reconnect_limit='∞'"))
        #expect(!script.contains("cmux_ssh_attach_reconnect_unbounded=1"))
    }

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
            "  count=$(grep -c '^auth$' \"$CMUX_TEST_LOG\" 2>/dev/null) || count=0",
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
            count=$(grep -c '^attach$' "$CMUX_TEST_LOG" 2>/dev/null) || count=0
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

    @Test func establishedSessionStopsAfterTheFiniteReconnectBudget() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-unclassified-reauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: true
        )
        let script = ([
            "cmux_ssh_attach_auth_pid=",
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "sleep() { :; }",
            "cmux_test_attach() {",
            "  count=$(grep -c '^attach$' \"$CMUX_TEST_LOG\" 2>/dev/null || true)",
            "  count=${count:-0}",
            "  printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"",
            "  if [ \"$count\" -eq 0 ]; then return 255; fi",
            "  return 7",
            "}",
            "cmux_ssh_attach_foreground_auth() {",
            "  count=$(grep -c '^auth$' \"$CMUX_TEST_LOG\" 2>/dev/null) || count=0",
            "  printf '%s\\n' auth >> \"$CMUX_TEST_LOG\"",
            "  if [ \"$count\" -eq 0 ]; then return 0; fi",
            "  if [ \"$count\" -eq 1 ]; then return 252; fi",
            "  if [ \"$count\" -le 21 ]; then return 254; fi",
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

        #expect(result.status == 254)
        let events = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        #expect(events.filter { $0 == "auth" }.count == 21)
        #expect(events.filter { $0 == "attach" }.count == 1)
    }

    @Test func permanentReauthenticationStillFailsClosedAfterEstablishedSession() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-permanent-reauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: true
        )
        let script = ([
            "cmux_ssh_attach_auth_pid=",
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "sleep() { :; }",
            "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 255; }",
            "cmux_ssh_attach_foreground_auth() {",
            "  count=$(grep -c '^auth$' \"$CMUX_TEST_LOG\" 2>/dev/null) || count=0",
            "  printf '%s\\n' auth >> \"$CMUX_TEST_LOG\"",
            "  if [ \"$count\" -eq 0 ]; then return 0; fi",
            "  return 255",
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

        #expect(result.status == 255)
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "auth\nattach\nauth\n")
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
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-backoff-transcript-\(UUID().uuidString)")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        defer {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: markerURL)
            try? FileManager.default.removeItem(at: transcriptURL)
        }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: reauthenticates
        )
        let script = ([
            "cmux_ssh_attach_signal_exit() {",
            "  cmux_ssh_attach_signal_status=\"$1\"",
            "  cmux_ssh_attach_signal_name=\"$2\"",
            "  if [ -n \"${cmux_ssh_attach_backoff_pid:-}\" ]; then",
            "    /bin/kill -TERM \"$cmux_ssh_attach_backoff_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_attach_backoff_pid\" 2>/dev/null || true",
            "    cmux_ssh_attach_backoff_pid=",
            "  elif [ \"${cmux_ssh_attach_backoff_launching:-0}\" = 1 ]; then",
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
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice

        try process.run()
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: markerURL.path),
              process.isRunning,
              Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(
            waitForFile(
                at: transcriptURL,
                containing: "remote PTY bridge closed; reattaching",
                while: process,
                timeout: 3
            )
        )

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

    @Test func reconnectBackoffPreservesQueuedTerminalInput() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-queued-input-\(UUID().uuidString)")
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-queued-input-transcript-\(UUID().uuidString)")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        defer {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: transcriptURL)
        }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "cmux_test_attach() {",
            "  count=$(grep -c '^attach$' \"$CMUX_TEST_LOG\" 2>/dev/null) || count=0",
            "  printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"",
            "  if [ \"$count\" -eq 0 ]; then return 255; fi",
            "  IFS= read -r cmux_test_input || return 42",
            "  printf 'input:%s\\n' \"$cmux_test_input\" >> \"$CMUX_TEST_LOG\"",
            "  return 0",
            "}",
        ] + retryLines).joined(separator: "\n")

        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import os, pty, sys; status = pty.spawn(['/bin/sh', '-c', sys.argv[1]]); sys.exit(os.waitstatus_to_exitcode(status))",
            script,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_TEST_LOG": logURL.path,
            "CMUX_SSH_RECONNECT_DELAY_SECONDS": "1",
            "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "1",
        ]) { _, override in override }
        process.standardInput = standardInput
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice

        try process.run()
        let enteredBackoff = waitForFile(
            at: transcriptURL,
            containing: "remote PTY bridge closed; reattaching",
            while: process,
            timeout: 3
        )
        #expect(enteredBackoff)
        if enteredBackoff {
            try standardInput.fileHandleForWriting.write(contentsOf: Data("queued-input\n".utf8))
        }
        let queuedInputReachedAttach = waitForFile(
            at: logURL,
            containing: "input:queued-input",
            while: process,
            timeout: 3
        )
        #expect(queuedInputReachedAttach)
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let logContents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<missing>"
        if queuedInputReachedAttach {
            #expect(logContents == "attach\nattach\ninput:queued-input\n")
        }
    }

    @Test(arguments: ["bad", "21", "999999999999999999999999999999"])
    func malformedOrOversizedReconnectLimitsRemainFinite(_ configuredLimit: String) throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "sleep() { :; }",
            "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 255; }",
        ] + retryLines).joined(separator: "\n")

        let result = try run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_SSH_RECONNECT_LIMIT": configuredLimit,
            ]
        )
        let attempts = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .count

        #expect(result.status == 255)
        // One initial attach plus at most the 20 reconnects is the hard
        // contract, regardless of user-provided limit text.
        #expect(attempts == 21)
    }

    @Test
    func retryableAttachIsCappedAtTwentyReconnects() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "sleep() { :; }",
            "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 255; }",
        ] + retryLines).joined(separator: "\n")

        let result = try run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_SSH_RECONNECT_LIMIT": "20",
            ]
        )

        #expect(result.status == 255)
        let attempts = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(attempts == Array(repeating: Substring("attach"), count: 21))
    }

    private func waitForFile(
        at url: URL,
        containing expectedContents: String,
        while process: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(expectedContents) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
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
