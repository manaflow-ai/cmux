import CmuxFoundation
import Foundation

/// Repository-scoped access to the injected Git process runner.
struct GitCommandExecutor: Sendable {
    let repositoryDirectory: String
    let commandRunner: any CommandRunning

    func run(_ arguments: [String], allowFailure: Bool = false) async throws -> String? {
        let fullArguments = ["-c", "core.quotepath=false"] + arguments
        let result = await commandRunner.run(
            directory: repositoryDirectory,
            executable: "/usr/bin/git",
            arguments: fullArguments,
            timeout: 30
        )
        if result.executionError == nil,
           !result.timedOut,
           result.exitStatus == 0,
           let stdout = result.stdout {
            return stdout
        }
        if allowFailure {
            return nil
        }
        let diagnostic = result.executionError
            ?? (result.timedOut ? "Git command timed out" : result.stderr)
            ?? "Git exited with status \(result.exitStatus.map(String.init) ?? "unknown")"
        throw DiffEngineError.commandFailed(arguments: fullArguments, diagnostic: diagnostic)
    }

    func repositoryRoot() async throws -> String {
        guard let output = try await run(["rev-parse", "--show-toplevel"], allowFailure: true) else {
            throw DiffEngineError.notGitRepository
        }
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw DiffEngineError.notGitRepository
        }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
    }
}
