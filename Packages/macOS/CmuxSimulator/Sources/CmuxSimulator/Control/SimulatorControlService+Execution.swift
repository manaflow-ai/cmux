import CmuxFoundation
import Foundation

extension SimulatorControlService {
    static let maximumRecentLogBytes = 2 * 1_024 * 1_024
    static let maximumClipboardBytes = 1 * 1_024 * 1_024
    static let maximumBoundedDiagnosticBytes = 64 * 1_024
    static let maximumInventoryBytes = 8 * 1_024 * 1_024
    static let maximumMutationOutputBytes = 256 * 1_024

    func run(
        executable: String = "/usr/bin/xcrun",
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async -> CommandResult {
        let result = await boundedCommands.runBounded(
            directory: currentDirectoryURL.path,
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout ?? commandTimeout,
            standardOutputLimit: outputLimit(arguments: arguments),
            standardErrorLimit: Self.maximumBoundedDiagnosticBytes
        )
        return CommandResult(
            stdout: String(decoding: result.standardOutput, as: UTF8.self),
            stderr: String(decoding: result.standardError, as: UTF8.self),
            exitStatus: result.exitStatus,
            timedOut: result.timedOut,
            executionError: result.executionError
        )
    }

    func output(
        executable: String = "/usr/bin/xcrun",
        arguments: [String],
        environment: [String: String] = [:],
        diagnosticArguments: [String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let result = await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        guard succeeded(result) else {
            throw failure(result: result, arguments: diagnosticArguments ?? arguments)
        }
        return Data((result.stdout ?? "").utf8)
    }

    func boundedOutput(
        executable: String = "/usr/bin/xcrun",
        arguments: [String],
        environment: [String: String] = [:],
        diagnosticArguments: [String]? = nil,
        standardOutputLimit: Int,
        timeout: TimeInterval? = nil
    ) async throws -> SimulatorBoundedCommandResult {
        let result = await boundedCommands.runBounded(
            directory: currentDirectoryURL.path,
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout ?? commandTimeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: Self.maximumBoundedDiagnosticBytes
        )
        let commandResult = CommandResult(
            stdout: String(decoding: result.standardOutput, as: UTF8.self),
            stderr: String(decoding: result.standardError, as: UTF8.self),
            exitStatus: result.exitStatus,
            timedOut: result.timedOut,
            executionError: result.executionError
        )
        guard succeeded(commandResult) else {
            throw failure(
                result: commandResult,
                arguments: diagnosticArguments ?? arguments
            )
        }
        return result
    }

    func succeeded(_ result: CommandResult) -> Bool {
        result.executionError == nil && !result.timedOut && result.exitStatus == 0
    }

    func diagnostic(for result: CommandResult) -> String {
        let stderr = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stdout.isEmpty { return stdout }
        if let executionError = result.executionError { return executionError }
        if result.timedOut { return "The Simulator command timed out." }
        return "The Simulator command exited with status \(result.exitStatus.map(String.init) ?? "unknown")."
    }

    func failure(result: CommandResult, arguments: [String]) -> SimulatorControlError {
        let code: String
        if result.executionError != nil {
            code = "command_launch_failed"
        } else if result.timedOut {
            code = "command_timed_out"
        } else {
            code = "simctl_failed"
        }
        return SimulatorControlError(code: code, arguments: arguments, message: diagnostic(for: result))
    }

    private func outputLimit(arguments: [String]) -> Int {
        let inventoryCommands: Set<String> = ["devices", "runtimes", "listapps"]
        if arguments.contains(where: inventoryCommands.contains) {
            return Self.maximumInventoryBytes
        }
        return Self.maximumMutationOutputBytes
    }

}
