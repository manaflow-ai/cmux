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

    @Test(arguments: ["0", "0000"])
    func zeroIsABudgetWhenTheCallerAcceptsIt(_ limit: String) throws {
        let result = try runShell(
            SSHReconnectBudget().limitNormalizationShellLines(
                variable: "cmux_test_limit", fallback: 86400, acceptsZero: true
            ) + ["printf '%s' \"$cmux_test_limit\""],
            environment: [SSHReconnectBudget().limitEnvironmentName: limit]
        )

        #expect(result.stdout == "0")
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))
    }

    @Test(arguments: [
        // (delay, maximum delay) -> (delay, maximum delay)
        (delay: nil, maximum: nil, resolved: "2 30"),
        (delay: "5", maximum: nil, resolved: "5 30"),
        (delay: "abc", maximum: nil, resolved: "2 30"),
        (delay: "1.5", maximum: nil, resolved: "2 30"),
        (delay: "0", maximum: nil, resolved: "2 30"),
        (delay: "007", maximum: nil, resolved: "2 30"),
        (delay: "45", maximum: nil, resolved: "30 30"),
        (delay: "99999999999999999999", maximum: nil, resolved: "30 30"),
        (delay: "99999999999999999999", maximum: "1", resolved: "1 1"),
        (delay: "60", maximum: "120", resolved: "60 120"),
        (delay: "5", maximum: "99999999999999999999", resolved: "5 86400"),
        (delay: "99999999999999999999", maximum: "99999999999999999999", resolved: "86400 86400"),
        (delay: "1m", maximum: nil, resolved: "2 30"),
    ] as [(delay: String?, maximum: String?, resolved: String)])
    func delaysAreWholeSecondsHeldToTheirCap(
        _ testCase: (delay: String?, maximum: String?, resolved: String)
    ) throws {
        let budget = SSHReconnectBudget()
        var environment: [String: String] = [:]
        environment[budget.delayEnvironmentName] = testCase.delay
        environment[budget.maximumDelayEnvironmentName] = testCase.maximum
        let result = try runShell(
            budget.delayNormalizationShellLines(variable: "cmux_test_delay", maximumVariable: "cmux_test_max")
                + ["printf '%s %s' \"$cmux_test_delay\" \"$cmux_test_max\""],
            environment: environment
        )

        #expect(result.stdout == testCase.resolved)
        // An oversized value must never reach `[ … -gt … ]`.
        #expect(!result.stderr.contains("integer expression expected"), Comment(rawValue: result.stderr))
        // Only a delay that was set and could not be used is reported.
        let rejected = testCase.delay.map { $0.isEmpty || $0.hasPrefix("0") || !$0.allSatisfy(\.isNumber) } ?? false
        #expect(
            result.stderr.contains("CMUX_SSH_RECONNECT_DELAY_SECONDS=\(testCase.delay ?? "")") == rejected,
            Comment(rawValue: result.stderr)
        )
    }

    private func runShell(
        _ lines: [String],
        environment extra: [String: String]
    ) throws -> (stdout: String, stderr: String) {
        let budget = SSHReconnectBudget()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", lines.joined(separator: "\n")]
        var environment = ProcessInfo.processInfo.environment
        for name in [budget.limitEnvironmentName, budget.delayEnvironmentName, budget.maximumDelayEnvironmentName] {
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
        return (String(data: stdoutData, encoding: .utf8) ?? "", String(data: stderrData, encoding: .utf8) ?? "")
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
