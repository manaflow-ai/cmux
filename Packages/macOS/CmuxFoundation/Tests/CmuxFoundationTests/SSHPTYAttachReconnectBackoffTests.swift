import Foundation
import Testing

@testable import CmuxFoundation

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/10173.
///
/// A host that stays unreachable used to retry every two seconds forever and
/// print two or three raw diagnostic lines per attempt into the terminal.
struct SSHPTYAttachReconnectBackoffTests {
    @Test func consecutiveShortFailuresGrowTheReconnectDelay() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("events.log")

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "date() { printf '%s\\n' 1000; }",
            "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
            "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 254; }",
        ] + retryLines).joined(separator: "\n")

        let result = try Self.run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_SSH_RECONNECT_LIMIT": "5",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ]
        )

        #expect(result.status == 254, Comment(rawValue: result.stderr))
        let events = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let delays = events.compactMap { $0.hasPrefix("sleep:") ? String($0.dropFirst(6)) : nil }
        #expect(delays == ["2", "4", "8", "16", "30"])
        #expect(events.filter { $0 == "attach" }.count == 6)
    }

    @Test func repeatedFailuresCollapseIntoOneStatusLinePerHostState() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "date() { printf '%s\\n' 1000; }",
            "sleep() { :; }",
            "cmux_test_attach() {",
            "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
            "  count=$((count + 1))",
            "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
            "  case \"$count\" in 1|2|3) return 255 ;; 4) return 251 ;; *) return 7 ;; esac",
            "}",
        ] + retryLines).joined(separator: "\n")

        let result = try Self.runOnTerminal(
            script,
            environment: [
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
                "CMUX_SSH_ATTACH_DIAGNOSTIC_LOG": directory.appendingPathComponent("diagnostics.log").path,
            ]
        )

        #expect(result.status == 7, Comment(rawValue: result.transcript))
        #expect(
            result.transcript.contains(
                "SSH host is unreachable; reconnecting (attempt 1, next retry in 2 seconds)."
            ),
            Comment(rawValue: result.transcript)
        )
        #expect(
            result.transcript.contains("reconnecting (attempt 3, next retry in 8 seconds)."),
            Comment(rawValue: result.transcript)
        )
        #expect(
            result.transcript.contains(
                "remote cmux daemon is busy; reconnecting (attempt 4, next retry in 16 seconds)."
            ),
            Comment(rawValue: result.transcript)
        )
        // Four failed attempts, but only two host states, so scrollback keeps two
        // lines: the repeated failures rewrite their state's line in place.
        // Split on line feeds only: a carriage return rewrites the current line
        // instead of starting a new one, which is exactly the collapse at issue.
        let statusLines = result.transcript.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
            .filter { $0.contains("reconnecting (attempt") }
        #expect(statusLines.count == 2, Comment(rawValue: result.transcript))
    }

    @Test func repeatedRawAttemptErrorsGoToTheDiagnosticLogInsteadOfThePane() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")
        let diagnosticsURL = directory.appendingPathComponent("diagnostics.log")

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        let script = ([
            "date() { printf '%s\\n' 1000; }",
            "sleep() { :; }",
            "cmux_test_attach() {",
            "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
            "  count=$((count + 1))",
            "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
            "  printf 'cmux-test-raw-noise %s\\n' \"$count\" >&2",
            "  if [ \"$count\" -ge 5 ]; then return 7; fi",
            "  return 255",
            "}",
        ] + retryLines).joined(separator: "\n")

        let result = try Self.runOnTerminal(
            script,
            environment: [
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_ATTACH_DIAGNOSTIC_LOG": diagnosticsURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ]
        )

        #expect(result.status == 7, Comment(rawValue: result.transcript))
        // The first failure keeps its raw diagnostics, and the fatal failure that
        // ends the loop reports its own; the repeats in between do not.
        #expect(result.transcript.contains("cmux-test-raw-noise 1"), Comment(rawValue: result.transcript))
        #expect(result.transcript.contains("cmux-test-raw-noise 5"), Comment(rawValue: result.transcript))
        #expect(!result.transcript.contains("cmux-test-raw-noise 2"), Comment(rawValue: result.transcript))
        #expect(!result.transcript.contains("cmux-test-raw-noise 3"), Comment(rawValue: result.transcript))
        #expect(!result.transcript.contains("cmux-test-raw-noise 4"), Comment(rawValue: result.transcript))
        #expect(
            result.transcript.contains(diagnosticsURL.path),
            Comment(rawValue: result.transcript)
        )

        let diagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
        #expect(diagnostics.contains("cmux-test-raw-noise 2"), Comment(rawValue: diagnostics))
        #expect(diagnostics.contains("cmux-test-raw-noise 3"), Comment(rawValue: diagnostics))
        #expect(diagnostics.contains("cmux-test-raw-noise 4"), Comment(rawValue: diagnostics))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-reconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func run(
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
        return (process.terminationStatus, String(data: stderrData, encoding: .utf8) ?? "")
    }

    /// Runs the retry loop with a real terminal on stdout and stderr, which is how
    /// a cmux pane runs it and the only mode in which status lines are printed.
    private static func runOnTerminal(
        _ script: String,
        environment overrides: [String: String]
    ) throws -> (status: Int32, transcript: String) {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-reconnect-transcript-\(UUID().uuidString)")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        defer {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: transcriptURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        )
    }
}
