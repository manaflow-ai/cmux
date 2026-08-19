import Foundation
import Testing

@testable import CmuxFoundation

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/10173.
///
/// A host that stays unreachable used to retry every two seconds forever and
/// print two or three raw diagnostic lines per attempt into the terminal.
struct SSHPTYAttachReconnectBackoffTests {
    // MARK: - The schedule itself

    @Test func consecutiveFailuresDoubleTheDelayUpToTheCeiling() {
        let policy = SSHPTYAttachReconnectBackoffPolicy(
            initialDelaySeconds: 2,
            maximumDelaySeconds: 30
        )
        let schedule = (1...8).map { policy.delaySeconds(afterConsecutiveFailures: $0) }
        #expect(schedule == [2, 4, 8, 16, 30, 30, 30, 30])
    }

    @Test func aStreakThatNeverEndsStaysAtTheCeiling() {
        let policy = SSHPTYAttachReconnectBackoffPolicy(
            initialDelaySeconds: 2,
            maximumDelaySeconds: 30
        )
        #expect(policy.delaySeconds(afterConsecutiveFailures: 10_000) == 30)
        #expect(policy.delaySeconds(afterConsecutiveFailures: .max) == 30)
    }

    /// A ceiling near `Int.max` used to trap on the doubling that produced it.
    @Test func anAbsurdCeilingClampsInsteadOfOverflowing() {
        let policy = SSHPTYAttachReconnectBackoffPolicy(
            initialDelaySeconds: 1,
            maximumDelaySeconds: .max
        )
        let cap = SSHPTYAttachReconnectBackoffPolicy.maximumConfigurableDelaySeconds
        #expect(policy.maximumDelaySeconds == cap)
        #expect(policy.delaySeconds(afterConsecutiveFailures: 1) == 1)
        #expect(policy.delaySeconds(afterConsecutiveFailures: 64) == cap)
        #expect(policy.delaySeconds(afterConsecutiveFailures: .max) == cap)
    }

    @Test func invalidConfigurationsClamp() {
        let cases: [(initial: Int, maximum: Int, expectedInitial: Int, expectedMaximum: Int)] = [
            (0, 30, 1, 30),
            (-5, 30, 1, 30),
            (2, 0, 1, 1),
            (2, -30, 1, 1),
            (90, 30, 30, 30),
            (.max, .max, 86_400, 86_400),
        ]
        for testCase in cases {
            let policy = SSHPTYAttachReconnectBackoffPolicy(
                initialDelaySeconds: testCase.initial,
                maximumDelaySeconds: testCase.maximum
            )
            #expect(policy.initialDelaySeconds == testCase.expectedInitial)
            #expect(policy.maximumDelaySeconds == testCase.expectedMaximum)
            #expect(policy.delaySeconds(afterConsecutiveFailures: 1) == testCase.expectedInitial)
        }
    }

    @Test(arguments: [-1, 0, 1])
    func theFirstFailureOfAStreakWaitsTheInitialDelay(consecutiveFailures: Int) {
        let policy = SSHPTYAttachReconnectBackoffPolicy(
            initialDelaySeconds: 3,
            maximumDelaySeconds: 30
        )
        #expect(policy.delaySeconds(afterConsecutiveFailures: consecutiveFailures) == 3)
    }

    @Test func onlyAConnectedAttemptCountsAsProgress() {
        let policy = SSHPTYAttachReconnectBackoffPolicy()
        let healthy = SSHPTYAttachReconnectBackoffPolicy.healthyAttemptSeconds
        #expect(policy.attemptProvedProgress(durationSeconds: 0) == false)
        #expect(policy.attemptProvedProgress(durationSeconds: healthy - 1) == false)
        #expect(policy.attemptProvedProgress(durationSeconds: healthy) == true)
    }

    // MARK: - What the pane shows

    @Test func theStatusLineNamesTheAttemptAndTheNextDelay() {
        let policy = SSHPTYAttachReconnectBackoffPolicy()
        #expect(
            policy.statusLine(attempt: 1, delaySeconds: 2)
                == "[cmux] reconnecting to the remote PTY (attempt 1, next retry in 2s)."
        )
        #expect(
            policy.statusLine(attempt: 27, delaySeconds: 30)
                == "[cmux] reconnecting to the remote PTY (attempt 27, next retry in 30s)."
        )
    }

    /// The wording stays neutral because a single attach status covers several
    /// host states: 255 is returned for a connect timeout, a refused connection,
    /// and a remote daemon that is not ready yet, all quoted in issue #10173.
    @Test func theStatusLineDoesNotGuessWhyTheHostFailed() {
        let line = SSHPTYAttachReconnectBackoffPolicy().statusLine(attempt: 3, delaySeconds: 8)
        #expect(!line.lowercased().contains("unreachable"))
        #expect(!line.lowercased().contains("lost"))
        #expect(!line.lowercased().contains("daemon"))
    }

    // MARK: - The generated loop follows the schedule

    @Test func theRetryLoopWaitsTheScheduledDelays() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("events.log")

        let policy = SSHPTYAttachReconnectBackoffPolicy(
            initialDelaySeconds: 2,
            maximumDelaySeconds: 30
        )
        let script = Self.script(
            stubs: [
                "date() { printf '%s\\n' 1000; }",
                "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
                "cmux_test_attach() { printf '%s\\n' attach >> \"$CMUX_TEST_LOG\"; return 254; }",
            ]
        )

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
        let events = try Self.events(in: logURL)
        let expected = (1...5).map { String(policy.delaySeconds(afterConsecutiveFailures: $0)) }
        #expect(Self.delays(in: events) == expected)
        #expect(events.filter { $0 == "attach" }.count == 6)
    }

    /// An attempt that stayed connected is progress, so the schedule restarts.
    @Test func aConnectedAttemptRestartsTheSchedule() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("events.log")
        let counterURL = directory.appendingPathComponent("attempts")
        let clockURL = directory.appendingPathComponent("clock")
        try "1000\n".write(to: clockURL, atomically: true, encoding: .utf8)

        let healthy = SSHPTYAttachReconnectBackoffPolicy.healthyAttemptSeconds
        let script = Self.script(
            stubs: [
                "date() { cat \"$CMUX_TEST_CLOCK\"; }",
                "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
                "  count=$((count + 1))",
                "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
                "  if [ \"$count\" -eq 3 ]; then",
                "    now=$(cat \"$CMUX_TEST_CLOCK\")",
                "    printf '%s\\n' \"$((now + \(healthy)))\" > \"$CMUX_TEST_CLOCK\"",
                "  fi",
                "  if [ \"$count\" -ge 6 ]; then return 7; fi",
                "  return 254",
                "}",
            ]
        )

        let result = try Self.run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_TEST_CLOCK": clockURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ]
        )

        #expect(result.status == 7, Comment(rawValue: result.stderr))
        #expect(Self.delays(in: try Self.events(in: logURL)) == ["2", "4", "2", "4", "8"])
    }

    /// A delay setting too large for shell arithmetic must clamp, not abort the
    /// loop with `value too great for base` before the first reattach.
    @Test(arguments: ["99999999999999999999", "18446744073709551616", "123456"])
    func anAbsurdDelaySettingClampsInsteadOfBreakingTheLoop(setting: String) throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("events.log")
        let counterURL = directory.appendingPathComponent("attempts")

        let script = Self.script(
            stubs: [
                "date() { printf '%s\\n' 1000; }",
                "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
                "  count=$((count + 1))",
                "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
                "  if [ \"$count\" -ge 2 ]; then return 7; fi",
                "  return 254",
                "}",
            ]
        )

        let result = try Self.run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": setting,
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": setting,
            ]
        )

        #expect(result.status == 7, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        let cap = String(SSHPTYAttachReconnectBackoffPolicy.maximumConfigurableDelaySeconds)
        #expect(Self.delays(in: try Self.events(in: logURL)) == [cap])
    }

    /// The reconnect limit is free-form text too, and an oversized one used to
    /// make both budget comparisons fail instead of answering.
    @Test func anAbsurdReconnectLimitDoesNotBreakTheBudgetChecks() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("events.log")
        let counterURL = directory.appendingPathComponent("attempts")

        let script = Self.script(
            stubs: [
                "date() { printf '%s\\n' 1000; }",
                "sleep() { printf 'sleep:%s\\n' \"$1\" >> \"$CMUX_TEST_LOG\"; }",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
                "  count=$((count + 1))",
                "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
                "  if [ \"$count\" -ge 3 ]; then return 7; fi",
                "  return 254",
                "}",
            ]
        )

        let result = try Self.run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_RECONNECT_LIMIT": "999999999999999999999",
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ]
        )

        #expect(result.status == 7, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        #expect(Self.delays(in: try Self.events(in: logURL)) == ["2", "4"])
    }

    // MARK: - The generated loop collapses its status output

    @Test func repeatedFailuresRewriteOneStatusLineInsteadOfAppendingMore() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")

        let script = Self.script(
            stubs: [
                "date() { printf '%s\\n' 1000; }",
                "sleep() { :; }",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
                "  count=$((count + 1))",
                "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
                "  if [ \"$count\" -ge 5 ]; then return 7; fi",
                "  return 255",
                "}",
            ]
        )

        let result = try Self.runOnTerminal(
            script,
            environment: [
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ],
            temporaryDirectory: directory
        )

        #expect(result.status == 7, Comment(rawValue: result.transcript))
        #expect(
            result.transcript.contains(
                "[cmux] reconnecting to the remote PTY (attempt 1, next retry in 2s)."
            ),
            Comment(rawValue: result.transcript)
        )
        #expect(
            result.transcript.contains("reconnecting to the remote PTY (attempt 4, next retry in 16s)."),
            Comment(rawValue: result.transcript)
        )
        // Four failed attempts, one status line. Split on line feeds only: a
        // carriage return rewrites the current line instead of starting a new
        // one, which is exactly the collapse at issue.
        #expect(Self.statusLineCount(in: result.transcript) == 1, Comment(rawValue: result.transcript))
    }

    @Test func onlyTheFirstFailureOfAStreakPrintsItsRawErrorOutput() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")
        let temporaryDirectory = directory.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let script = Self.script(
            stubs: [
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
            ]
        )

        let result = try Self.runOnTerminal(
            script,
            environment: [
                "CMUX_TEST_COUNTER": counterURL.path,
                "CMUX_SSH_RECONNECT_DELAY_SECONDS": "2",
                "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS": "30",
            ],
            temporaryDirectory: temporaryDirectory
        )

        #expect(result.status == 7, Comment(rawValue: result.transcript))
        #expect(result.transcript.contains("cmux-test-raw-noise 1"), Comment(rawValue: result.transcript))
        for repeated in 2...5 {
            #expect(
                !result.transcript.contains("cmux-test-raw-noise \(repeated)"),
                Comment(rawValue: result.transcript)
            )
        }
        // Retrying stopped while repeats were hidden, so the pane says so rather
        // than ending on a silenced failure.
        #expect(
            result.transcript.contains("stopped reconnecting to the remote PTY"),
            Comment(rawValue: result.transcript)
        )
        // Nothing about the outage is written to disk.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        #expect(leftovers.isEmpty, Comment(rawValue: leftovers.joined(separator: ", ")))
    }

    /// An outage that reauthenticates every cycle must not print the same attach
    /// error once per cycle: the authentication prompt speaks, the repeats do not.
    @Test func reauthenticatingBetweenAttemptsKeepsRepeatsHidden() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")

        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: true
        )
        let script = ([
            "cmux_ssh_attach_auth_pid=",
            "cmux_ssh_attach_signal_exit() { exit \"$1\"; }",
            "date() { printf '%s\\n' 1000; }",
            "sleep() { :; }",
            "cmux_ssh_attach_foreground_auth() { printf 'cmux-test-auth\\n' >&2; return 0; }",
            "cmux_test_attach() {",
            "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
            "  count=$((count + 1))",
            "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
            "  printf 'cmux-test-raw-noise %s\\n' \"$count\" >&2",
            "  if [ \"$count\" -ge 4 ]; then return 7; fi",
            "  return 255",
            "}",
        ] + retryLines).joined(separator: "\n")

        let result = try Self.runOnTerminal(
            script,
            environment: ["CMUX_TEST_COUNTER": counterURL.path],
            temporaryDirectory: directory
        )

        #expect(result.status == 7, Comment(rawValue: result.transcript))
        // The prompt is never quieted; the attach repeats behind it are.
        #expect(
            result.transcript.components(separatedBy: "cmux-test-auth").count - 1 >= 2,
            Comment(rawValue: result.transcript)
        )
        #expect(result.transcript.contains("cmux-test-raw-noise 1"), Comment(rawValue: result.transcript))
        for repeated in 2...4 {
            #expect(
                !result.transcript.contains("cmux-test-raw-noise \(repeated)"),
                Comment(rawValue: result.transcript)
            )
        }
    }

    /// A session that reattaches and then ends cleanly is not a stopped reconnect.
    @Test func aCleanExitAfterAnOutageSaysNothingAboutHiddenErrors() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterURL = directory.appendingPathComponent("attempts")

        let script = Self.script(
            stubs: [
                "date() { printf '%s\\n' 1000; }",
                "sleep() { :; }",
                "cmux_test_attach() {",
                "  count=$(cat \"$CMUX_TEST_COUNTER\" 2>/dev/null) || count=0",
                "  count=$((count + 1))",
                "  printf '%s\\n' \"$count\" > \"$CMUX_TEST_COUNTER\"",
                "  printf 'cmux-test-raw-noise %s\\n' \"$count\" >&2",
                "  if [ \"$count\" -ge 3 ]; then return 0; fi",
                "  return 255",
                "}",
            ]
        )

        let result = try Self.runOnTerminal(
            script,
            environment: ["CMUX_TEST_COUNTER": counterURL.path],
            temporaryDirectory: directory
        )

        #expect(result.status == 0, Comment(rawValue: result.transcript))
        #expect(
            !result.transcript.contains("stopped reconnecting"),
            Comment(rawValue: result.transcript)
        )
        #expect(Self.statusLineCount(in: result.transcript) == 1, Comment(rawValue: result.transcript))
    }

    // MARK: - Harness

    private static func script(stubs: [String]) -> String {
        let retryLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_test_attach",
            reauthenticates: false
        )
        return (stubs + retryLines).joined(separator: "\n")
    }

    private static func events(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private static func delays(in events: [String]) -> [String] {
        events.compactMap { $0.hasPrefix("sleep:") ? String($0.dropFirst(6)) : nil }
    }

    private static func statusLineCount(in transcript: String) -> Int {
        transcript.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
            .filter { $0.contains("reconnecting to the remote PTY (attempt") }
            .count
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
    ///
    /// `temporaryDirectory` becomes the loop's `TMPDIR`, so a test can prove the
    /// loop wrote nothing to disk.
    private static func runOnTerminal(
        _ script: String,
        environment overrides: [String: String],
        temporaryDirectory: URL
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
        process.environment = ProcessInfo.processInfo.environment
            .merging(overrides) { _, override in override }
            .merging(["TMPDIR": temporaryDirectory.path]) { _, override in override }
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
