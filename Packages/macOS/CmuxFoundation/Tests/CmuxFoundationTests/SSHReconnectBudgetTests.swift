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
