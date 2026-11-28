import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct SSHReconnectBudgetTests {
    @Test(arguments: [
        (limit: "1", resolved: "1"),
        (limit: "20", resolved: "20"),
        // A well-formed budget above the historical 20-attempt ceiling used to
        // be discarded without a word. It is honored now.
        (limit: "21", resolved: "21"),
        (limit: "50", resolved: "50"),
        (limit: "86400", resolved: "86400"),
        // Leading zeros are normalization, not rejection.
        (limit: "007", resolved: "7"),
    ])
    func honorsWellFormedBudgetsSilently(_ testCase: (limit: String, resolved: String)) throws {
        let result = try resolve(testCase.limit)

        #expect(result.resolved == testCase.resolved)
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
    }

    @Test(arguments: ["abc", "-5", "1e3", "1.5", " 20", "0", "0000"])
    func unusableBudgetsFailClosedAndSaySo(_ limit: String) throws {
        let result = try resolve(limit)

        #expect(result.resolved == String(SSHReconnectBudget().fallbackLimit))
        #expect(result.stderr.contains("CMUX_SSH_RECONNECT_LIMIT=\(limit)"), Comment(rawValue: result.stderr))
        #expect(result.stderr.contains("using \(SSHReconnectBudget().fallbackLimit)."), Comment(rawValue: result.stderr))
    }

    @Test(arguments: ["86401", "99999", "999999", "99999999999999999999"])
    func oversizedBudgetsClampToTheCeilingAndSaySo(_ limit: String) throws {
        let result = try resolve(limit)

        // A value with more digits than the shell's integer range must be
        // rejected by length, before any `[ … -gt … ]` tries to compare it.
        #expect(result.resolved == String(SSHReconnectBudget().maximumLimit))
        #expect(!result.stderr.contains("integer expression expected"), Comment(rawValue: result.stderr))
        #expect(result.stderr.contains("using \(SSHReconnectBudget().maximumLimit)."), Comment(rawValue: result.stderr))
    }

    @Test func unsetBudgetUsesTheFallbackWithoutComplaining() throws {
        let result = try resolve(nil)

        #expect(result.resolved == String(SSHReconnectBudget().fallbackLimit))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
    }

    @Test func callerSuppliedFallbackSurvivesItsOwnNormalization() throws {
        let result = try resolve(nil, fallback: SSHReconnectBudget().maximumLimit)

        #expect(result.resolved == String(SSHReconnectBudget().maximumLimit))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
    }

    @Test(arguments: [
        (delay: nil as String?, resolved: "2"),
        (delay: "1", resolved: "1"),
        (delay: "7", resolved: "7"),
        (delay: "007", resolved: "7"),
        (delay: "30", resolved: "30"),
        // Non-numeric text is not a delay; use the default instead of handing
        // it to `sleep`, which would fail and turn the loop into a busy spin.
        (delay: "abc", resolved: "2"),
        (delay: "1.5", resolved: "2"),
        (delay: "-5", resolved: "2"),
        (delay: "", resolved: "2"),
        // Zero would retry with no wait at all.
        (delay: "0", resolved: "1"),
        (delay: "0000", resolved: "1"),
        (delay: "31", resolved: "30"),
        (delay: "99999999999999999999", resolved: "30"),
    ])
    func delayIsNormalizedIntoTheSleepableRange(_ testCase: (delay: String?, resolved: String)) throws {
        let budget = SSHReconnectBudget()
        let variable = "cmux_test_delay"
        let script = (budget.delayNormalizationShellLines(variable: variable)
            + ["printf '%s' \"$\(variable)\""]).joined(separator: "\n")

        let result = try runShell(
            script,
            environment: [budget.delayEnvironmentName: testCase.delay]
        )

        #expect(result.stdout == testCase.resolved)
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
    }

    @Test func attachRetryLoopEndsWhenTheEnvironmentIsGarbage() throws {
        let budget = SSHReconnectBudget()
        // The stub stands in for an attach that keeps losing its connection.
        // It gives up on its own well past the clamped budget, so a loop that
        // never reaches its limit still terminates and the test can say so.
        let runawayAttempts = budget.maximumLimit + 10
        let script = ([
            "cmux_test_attempts=0",
            "cmux_test_sleep_arg=",
            "sleep() { cmux_test_sleep_arg=\"$1\"; }",
            "cmux_test_attach() { cmux_test_attempts=$((cmux_test_attempts + 1)); "
                + "if [ \"$cmux_test_attempts\" -gt \(runawayAttempts) ]; then printf 'runaway %s %s' \"$cmux_test_attempts\" \"$cmux_test_sleep_arg\"; exit 0; fi; "
                + "return 255; }",
            "trap 'printf \"attempts=%s sleep=%s\" \"$cmux_test_attempts\" \"$cmux_test_sleep_arg\"' EXIT",
        ] + budget.attachRetryLoopShellLines(attachCommand: "cmux_test_attach"))
            .joined(separator: "\n")

        let result = try runShell(
            script,
            environment: [
                budget.limitEnvironmentName: "99999999999999999999",
                budget.delayEnvironmentName: "abc",
            ]
        )

        #expect(result.status == 255)
        #expect(!result.stderr.contains("integer expression expected"), Comment(rawValue: result.stderr))
        #expect(!result.stdout.contains("runaway"), Comment(rawValue: result.stdout))
        // One initial attempt plus `maximumLimit` retries, each waiting the
        // default delay rather than the rejected text.
        #expect(result.stdout == "attempts=\(budget.maximumLimit + 1) sleep=\(budget.fallbackDelaySeconds)")
    }

    @Test func attachRetryLoopHonorsAConfiguredBudgetAndExportsItNormalized() throws {
        let budget = SSHReconnectBudget()
        let script = ([
            "cmux_test_attempts=0",
            "sleep() { :; }",
            "cmux_test_attach() { cmux_test_attempts=$((cmux_test_attempts + 1)); "
                + "printf '%s/%s/%s/%s\\n' \"$cmux_test_attempts\" \"$(printenv CMUX_SSH_RECONNECT_DELAY_SECONDS)\" "
                + "\"$(printenv CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT)\" \"$(printenv CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS)\"; "
                + "return 254; }",
        ] + budget.attachRetryLoopShellLines(attachCommand: "cmux_test_attach"))
            .joined(separator: "\n")

        let result = try runShell(
            script,
            environment: [
                budget.limitEnvironmentName: "003",
                budget.delayEnvironmentName: "0",
            ]
        )

        #expect(result.status == 254)
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        // The child attach sees the normalized values, not the raw ones.
        #expect(result.stdout == "1/1/3/1\n2/1/3/1\n3/1/3/1\n4/1/3/1\n")
    }

    // Before the shared loop, a limit of 0 meant "attach once, never
    // reconnect"; it must keep meaning that, not the 86,400-retry ceiling.
    @Test(arguments: ["0", "000"])
    func attachRetryLoopTreatsZeroAsNoReconnect(limit: String) throws {
        let budget = SSHReconnectBudget()
        let script = ([
            "sleep() { :; }",
            "cmux_test_attach() { printf 'attempt\\n'; return 255; }",
        ] + budget.attachRetryLoopShellLines(attachCommand: "cmux_test_attach"))
            .joined(separator: "\n")

        let result = try runShell(script, environment: [budget.limitEnvironmentName: limit])

        #expect(result.status == 255)
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
        #expect(result.stdout == "attempt\n")
    }

    @Test func attachRetryLoopStopsOnANonRetryableStatus() throws {
        let budget = SSHReconnectBudget()
        let script = ([
            "cmux_test_attach() { printf 'attempt\\n'; return 3; }",
        ] + budget.attachRetryLoopShellLines(attachCommand: "cmux_test_attach"))
            .joined(separator: "\n")

        let result = try runShell(script, environment: [:])

        #expect(result.status == 3)
        #expect(result.stdout == "attempt\n")
    }

    private func runShell(
        _ script: String,
        environment overrides: [String: String?]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        for name in [
            SSHReconnectBudget().limitEnvironmentName,
            SSHReconnectBudget().delayEnvironmentName,
            "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT",
            "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
        ] {
            environment.removeValue(forKey: name)
        }
        for (name, value) in overrides {
            environment[name] = value
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func resolve(
        _ limit: String?,
        fallback: Int = SSHReconnectBudget().fallbackLimit
    ) throws -> (resolved: String, stderr: String) {
        let variable = "cmux_test_limit"
        let script = (SSHReconnectBudget().limitNormalizationShellLines(
            variable: variable,
            fallback: fallback
        ) + ["printf '%s' \"$\(variable)\""]).joined(separator: "\n")

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: SSHReconnectBudget().limitEnvironmentName)
        if let limit {
            environment[SSHReconnectBudget().limitEnvironmentName] = limit
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
