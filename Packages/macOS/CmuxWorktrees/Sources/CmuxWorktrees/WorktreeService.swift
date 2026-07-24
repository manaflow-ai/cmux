import CmuxFoundation
import Foundation

/// Performs stateless Git worktree operations through an injected execution host.
///
/// Git is the sole source of truth. The service writes no repository metadata
/// beyond standard Git config and branch refs, and it re-reads Git before every
/// destructive transition.
public struct WorktreeService: Sendable {
    static let gitEnvironment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    ]
    static let readTimeout: TimeInterval = 30
    static let addTimeout: TimeInterval = 180

    let postCreateHooks: [any WorktreePostCreateHook]
    let parser: WorktreePorcelainParser

    /// Creates a stateless worktree service.
    /// - Parameter postCreateHooks: Caller-owned hooks run after Git add and submodule initialization.
    public init(postCreateHooks: [any WorktreePostCreateHook] = []) {
        self.postCreateHooks = postCreateHooks
        self.parser = WorktreePorcelainParser()
    }

    /// Returns the repository-local Git config key that records a branch's creation base.
    /// - Parameter branch: The full local branch name.
    /// - Returns: A `branch.<name>.base` config key shared by writers and readers.
    public static func branchBaseConfigKey(for branch: String) -> String {
        "branch.\(branch).base"
    }

    func ensureAvailable(_ host: any WorktreeExecutionHost) async throws {
        guard await host.isAvailable() else {
            throw WorktreeServiceError.hostUnavailable(host.id)
        }
    }

    func ensureIdentityHost(
        _ identity: WorktreeIdentity,
        matches host: any WorktreeExecutionHost
    ) throws {
        guard identity.host == host.id else {
            throw WorktreeServiceError.hostMismatch(expected: identity.host, actual: host.id)
        }
    }

    func runGit(
        on host: any WorktreeExecutionHost,
        directory: String,
        arguments: [String],
        timeout: TimeInterval? = WorktreeService.readTimeout
    ) async throws -> CommandResult {
        let result = await host.run(
            directory: directory,
            executable: "git",
            arguments: arguments,
            environment: WorktreeService.gitEnvironment,
            timeout: timeout
        )
        return try successfulResult(
            result,
            executable: "git",
            arguments: arguments,
            timeout: timeout
        )
    }

    func successfulResult(
        _ result: CommandResult,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        if result.timedOut {
            throw WorktreeServiceError.commandTimedOut(command: command, seconds: timeout ?? 0)
        }
        if let executionError = result.executionError {
            throw WorktreeServiceError.commandFailed(
                command: command,
                exitStatus: nil,
                message: executionError
            )
        }
        guard result.exitStatus == 0 else {
            throw WorktreeServiceError.commandFailed(
                command: command,
                exitStatus: result.exitStatus,
                message: commandMessage(result)
            )
        }
        return result
    }

    func commandMessage(_ result: CommandResult) -> String {
        [result.stderr, result.stdout]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    func samePath(_ lhs: String, _ rhs: String) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }
}
