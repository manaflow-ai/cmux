import Foundation
import Testing

@testable import CmuxFoundation

/// The Cloud VM attach loop, run under `/bin/sh` with an attach that always
/// fails as retryable (#10419).
@Suite(.serialized)
struct CloudVMAttachRetryLoopScriptBuilderTests {
    @Test func defaultsRetryEveryTwoSecondsWithTheFullBudget() throws {
        let run = try runLoop(environment: [:], attachStatus: 255, stopAfter: 1)
        #expect(run.resolved == "86400 2")
        #expect(run.stderr.isEmpty, Comment(rawValue: run.stderr))
    }

    @Test func aDelaySleepCannotReadWaitsTheDefaultInstead() throws {
        let run = try runLoop(
            environment: ["CMUX_SSH_RECONNECT_LIMIT": "1", "CMUX_SSH_RECONNECT_DELAY_SECONDS": "abc"],
            attachStatus: 255
        )
        #expect(run.status == 255)
        #expect(run.attempts == 2)
        #expect(run.sleeps == ["2"], "slept \(run.sleeps)")
        let notices = run.stderr.components(separatedBy: "CMUX_SSH_RECONNECT_DELAY_SECONDS=abc").count - 1
        #expect(notices == 1, Comment(rawValue: run.stderr))
    }

    /// The loop has no backoff, so the supervisor's 30-second cap does not apply.
    @Test func aLongFixedDelayIsKept() throws {
        let run = try runLoop(
            environment: ["CMUX_SSH_RECONNECT_DELAY_SECONDS": "60"],
            attachStatus: 255,
            stopAfter: 1
        )
        #expect(run.resolved == "86400 60")
        #expect(run.stderr.isEmpty, Comment(rawValue: run.stderr))
    }

    @Test func anOversizedLimitIsTheCeilingAndIsSaidOnce() throws {
        let run = try runLoop(
            environment: ["CMUX_SSH_RECONNECT_LIMIT": "99999999999999999999"],
            attachStatus: 255,
            stopAfter: 1
        )
        #expect(run.resolved == "86400 2")
        #expect(!run.stderr.contains("integer expression expected"), Comment(rawValue: run.stderr))
        #expect(run.stderr.contains("CMUX_SSH_RECONNECT_LIMIT=99999999999999999999"), Comment(rawValue: run.stderr))
    }

    @Test func aLimitOfZeroMeansOneAttempt() throws {
        let run = try runLoop(environment: ["CMUX_SSH_RECONNECT_LIMIT": "0"], attachStatus: 255)
        #expect(run.status == 255)
        #expect(run.attempts == 1)
        #expect(run.stderr.isEmpty, Comment(rawValue: run.stderr))
    }

    @Test func aNonRetryableExitEndsTheLoop() throws {
        let run = try runLoop(environment: [:], attachStatus: 3)
        #expect(run.status == 3)
        #expect(run.attempts == 1)
    }

    @Test func theAttachSeesTheSettingsItWasGiven() throws {
        let run = try runLoop(
            environment: ["CMUX_SSH_RECONNECT_LIMIT": "0", "CMUX_SSH_RECONNECT_DELAY_SECONDS": "abc"],
            attachStatus: 255
        )
        // The attach command normalizes the reconnect settings itself; the loop
        // must not rewrite them. Its own retry defaults are the normalized copies.
        #expect(run.attachEnvironment == "0 abc 0 2")
    }

    /// The attach command's retry reads the defaults as given, with no ceiling
    /// and no delay check, so they have to be the normalized values.
    @Test func theAttachRetryDefaultsAreTheNormalizedSettings() throws {
        let run = try runLoop(
            environment: ["CMUX_SSH_RECONNECT_LIMIT": "99999999999999999999", "CMUX_SSH_RECONNECT_DELAY_SECONDS": "abc"],
            attachStatus: 255,
            stopAfter: 1
        )
        #expect(run.attachEnvironment == "99999999999999999999 abc 86400 2")
    }

    @Test func anExplicitAttachRetrySettingIsKept() throws {
        let run = try runLoop(
            environment: [
                "CMUX_SSH_RECONNECT_LIMIT": "99999999999999999999",
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT": "5",
                "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS": "7",
            ],
            attachStatus: 255,
            stopAfter: 1
        )
        #expect(run.attachEnvironment == "99999999999999999999 2 5 7")
    }

    private struct LoopRun {
        var status: Int32
        var attempts: Int
        /// The argument of each `sleep` the loop ran, in order.
        var sleeps: [String]
        var stderr: String
        var resolved: String
        var attachEnvironment: String
    }

    /// `stopAfter` ends the loop from inside the attach after that many attempts,
    /// printing the normalized settings, so a long budget can be checked quickly.
    private func runLoop(
        environment extra: [String: String],
        attachStatus: Int32,
        stopAfter: Int? = nil
    ) throws -> LoopRun {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-vm-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls").path
        let seen = root.appendingPathComponent("seen").path
        let slept = root.appendingPathComponent("slept").path
        let builder = CloudVMAttachRetryLoopScriptBuilder()
        // `retryLoopLines` calls `sleep` by name, so this records the wait instead of taking it.
        var attach = [
            "sleep() { printf '%s\\n' \"$1\" >> '\(slept)'; }",
            "cmux_freestyle_attach() {",
            "  echo attempt >> '\(calls)'",
            "  printf '%s %s %s %s' \"$CMUX_SSH_RECONNECT_LIMIT\" \"$CMUX_SSH_RECONNECT_DELAY_SECONDS\" "
                + "\"$CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT\" \"$CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS\" > '\(seen)'",
        ]
        if let stopAfter {
            attach.append(
                "  if [ \"$(wc -l < '\(calls)')\" -ge \(stopAfter) ]; then "
                    + "printf '%s %s' \"$cmux_freestyle_reconnect_limit\" \"$cmux_freestyle_reconnect_delay\"; exit 0; fi"
            )
        }
        attach += ["  return \(attachStatus)", "}"]
        let script = (builder.configurationLines + attach + builder.retryLoopLines).joined(separator: "\n")

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        for name in [
            "CMUX_SSH_RECONNECT_LIMIT", "CMUX_SSH_RECONNECT_DELAY_SECONDS", "CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS",
            "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT", "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
        ] {
            environment.removeValue(forKey: name)
        }
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let attempts = ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
        return LoopRun(
            status: process.terminationStatus,
            attempts: attempts,
            sleeps: ((try? String(contentsOfFile: slept, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init),
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            resolved: String(data: stdoutData, encoding: .utf8) ?? "",
            attachEnvironment: (try? String(contentsOfFile: seen, encoding: .utf8)) ?? ""
        )
    }
}
