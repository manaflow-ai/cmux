import Foundation
import Testing

@testable import CmuxFoundation

struct SSHReconnectBudgetShellPolicyTests {
    private static let oversizedValue = "99999999999999999999"

    @Test func retryLimitEndsTheLoopWhenTheBudgetIsSpent() throws {
        let result = try runBudgetCheck(retriesTaken: 5, limit: "5")

        #expect(result.status == 255)
        #expect(result.stderr.isEmpty)
    }

    @Test func retryLimitKeepsTheLoopRunningBelowTheBudget() throws {
        let result = try runBudgetCheck(retriesTaken: 4, limit: "5")

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
    }

    @Test func oversizedRetryLimitStillAnswersTheBudgetComparison() throws {
        let result = try runBudgetCheck(
            retriesTaken: SSHReconnectBudgetShellPolicy.maximumConfigurableRetryLimit,
            limit: Self.oversizedValue
        )

        // Without a ceiling the comparison errors instead of answering, and a
        // budget that never answers stops bounding the loop it belongs to.
        #expect(result.status == 255)
        #expect(result.stderr.isEmpty)
    }

    @Test func oversizedRetryLimitDoesNotEndTheLoopEarly() throws {
        let result = try runBudgetCheck(retriesTaken: 5, limit: Self.oversizedValue)

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
    }

    @Test func zeroPaddedRetryLimitIsReadAsItsDigits() throws {
        // The ceiling is applied by counting digits, so padding has to come off
        // first: "0000002" is a budget of two retries, not of a seven-digit
        // number of them.
        let spent = try runBudgetCheck(retriesTaken: 2, limit: "0000002")
        let remaining = try runBudgetCheck(retriesTaken: 1, limit: "0000002")

        #expect(spent.status == 255)
        #expect(remaining.status == 0)
        #expect(spent.stderr.isEmpty)
        #expect(remaining.stderr.isEmpty)
    }

    @Test func nonNumericRetryLimitFallsBackToTheDefaultBudget() throws {
        let spent = try runBudgetCheck(
            retriesTaken: SSHReconnectBudgetShellPolicy.defaultRetryLimit,
            limit: "not-a-number"
        )
        let remaining = try runBudgetCheck(
            retriesTaken: SSHReconnectBudgetShellPolicy.defaultRetryLimit - 1,
            limit: "not-a-number"
        )

        #expect(spent.status == 255)
        #expect(remaining.status == 0)
        #expect(spent.stderr.isEmpty)
        #expect(remaining.stderr.isEmpty)
    }

    @Test func oversizedDelayIsClampedToAnIntervalSleepAccepts() throws {
        let waited = try runDelay(delaySeconds: Self.oversizedValue)

        #expect(waited == "\(SSHReconnectBudgetShellPolicy.maximumConfigurableDelaySeconds)")
    }

    @Test func nonNumericDelayFallsBackToTheDefaultInterval() throws {
        let waited = try runDelay(delaySeconds: "half a minute")

        #expect(waited == "\(SSHReconnectBudgetShellPolicy.defaultDelaySeconds)")
    }

    @Test func configuredDelayIsWaitedAsWritten() throws {
        #expect(try runDelay(delaySeconds: "7") == "7")
        // An explicit zero asks for no wait at all, which the loop honors.
        #expect(try runDelay(delaySeconds: "0") == "0")
    }

    /// Runs the policy's budget check with a retry count and returns its outcome.
    ///
    /// The check exits with the attach status once the budget is spent, so a
    /// script that reaches its final line still had budget left.
    private func runBudgetCheck(
        retriesTaken: Int,
        limit: String
    ) throws -> (status: Int32, stderr: String) {
        let script = (SSHReconnectBudgetShellPolicy.configurationLines + [
            "cmux_test_retry=\(retriesTaken)",
            "cmux_test_status=255",
            SSHReconnectBudgetShellPolicy.limitReachedCommand(
                retryCountVariable: "cmux_test_retry",
                statusVariable: "cmux_test_status"
            ),
            "exit 0",
        ]).joined(separator: "\n")

        return try run(
            script,
            environment: [SSHReconnectBudgetShellPolicy.retryLimitVariable: limit]
        )
    }

    /// Returns the interval the policy's delay command hands to `sleep`.
    private func runDelay(delaySeconds: String) throws -> String {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-reconnect-delay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let script = ([
            "sleep() { printf '%s' \"$1\" > \"$CMUX_TEST_LOG\"; }",
        ] + SSHReconnectBudgetShellPolicy.configurationLines + [
            SSHReconnectBudgetShellPolicy.delayCommand,
        ]).joined(separator: "\n")

        let result = try run(
            script,
            environment: [
                "CMUX_TEST_LOG": logURL.path,
                SSHReconnectBudgetShellPolicy.delaySecondsVariable: delaySeconds,
            ]
        )

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        return (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
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
