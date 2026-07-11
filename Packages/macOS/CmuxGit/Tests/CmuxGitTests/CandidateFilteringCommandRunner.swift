import CmuxFoundation
import Foundation

/// Records worktree-include Git calls and returns a bounded ignored-path fixture.
actor CandidateFilteringCommandRunner: StandardInputCommandRunning {
    struct Invocation: Sendable {
        let arguments: [String]
        let timeout: TimeInterval?
        let standardInputByteCount: Int?
    }

    private var recordedInvocations: [Invocation] = []
    private let collapsedDirectoryCount: Int

    init(collapsedDirectoryCount: Int = 1) {
        self.collapsedDirectoryCount = collapsedDirectoryCount
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedInvocations.append(Invocation(
            arguments: arguments,
            timeout: timeout,
            standardInputByteCount: nil
        ))
        let stdout: String
        if arguments.contains("--directory"), arguments.contains("--exclude-standard") {
            let paths = collapsedDirectoryCount == 1
                ? ["node_modules/"]
                : (0..<collapsedDirectoryCount).map { "node_modules/pkg-\($0)/" }
            stdout = paths.joined(separator: "\0") + "\0"
        } else if arguments.contains("--directory") {
            stdout = "node_modules/\0"
        } else {
            stdout = ".env\0"
        }
        return successfulResult(stdout: stdout)
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedInvocations.append(Invocation(
            arguments: arguments,
            timeout: timeout,
            standardInputByteCount: standardInput.count
        ))
        let candidates = String(decoding: standardInput, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
        let ignored = candidates.filter { $0 == ".env" }
        let stdout = ignored.map(String.init).joined(separator: "\0") + (ignored.isEmpty ? "" : "\0")
        return successfulResult(stdout: stdout)
    }

    func invocations() -> [Invocation] {
        recordedInvocations
    }

    private func successfulResult(stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
