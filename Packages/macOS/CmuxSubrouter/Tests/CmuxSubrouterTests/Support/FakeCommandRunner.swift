import Foundation
import CmuxFoundation

/// A scriptable ``CommandRunning``: returns per-executable results and
/// records every invocation, so switcher tests never spawn a process.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    // Test-only fake; mutated and read on the test's single task.
    struct Invocation: Equatable {
        var directory: String
        var executable: String
        var arguments: [String]
        var timeout: TimeInterval?
    }

    /// Results keyed by executable name; unlisted executables fail to launch.
    var resultsByExecutable: [String: CommandResult] = [:]
    private(set) var invocations: [Invocation] = []

    static let launchFailure = CommandResult(
        stdout: nil,
        stderr: nil,
        exitStatus: nil,
        timedOut: false,
        executionError: "command not found"
    )

    static func success(stdout: String = "") -> CommandResult {
        CommandResult(stdout: stdout, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
    }

    static func failure(stderr: String, exitStatus: Int32 = 1) -> CommandResult {
        CommandResult(stdout: nil, stderr: stderr, exitStatus: exitStatus, timedOut: false, executionError: nil)
    }

    static let timeout = CommandResult(
        stdout: nil,
        stderr: nil,
        exitStatus: nil,
        timedOut: true,
        executionError: nil
    )

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(
            Invocation(
                directory: directory,
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        )
        return resultsByExecutable[executable] ?? Self.launchFailure
    }
}
