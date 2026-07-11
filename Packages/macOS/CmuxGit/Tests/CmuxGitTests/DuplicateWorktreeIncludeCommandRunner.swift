import CmuxFoundation
import Foundation

/// Returns the same 5,001 paths from both worktree-include matching passes.
actor DuplicateWorktreeIncludeCommandRunner: OutputLimitedCommandRunning {
    let paths: [String]
    private let pathOutput: String

    init(pathCount: Int = 5_001) {
        paths = (0..<pathCount).map { "cache/file-\($0)" }
        pathOutput = paths.joined(separator: "\0") + "\0"
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let stdout = arguments.contains("--directory") && !arguments.contains("--exclude-standard")
            ? "cache/\0"
            : pathOutput
        return success(stdout: stdout)
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult {
        await run(directory: directory, executable: executable, arguments: arguments, timeout: timeout)
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval?
    ) async -> CommandResult {
        success(stdout: String(decoding: standardInput, as: UTF8.self))
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult {
        await run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    private func success(stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
