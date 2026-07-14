import CmuxFoundation
import Foundation

/// Runs worktree risk probes without retaining path-sized Git output in cmux.
struct WorktreeSidebarBoundedGitProbe: Sendable {
    private let commands: any CommandRunning
    private let timeout: TimeInterval

    init(
        commands: any CommandRunning,
        timeout: TimeInterval
    ) {
        self.commands = commands
        self.timeout = timeout
    }

    func hasVisibleChanges(
        commandDirectory: String,
        worktreePath: String
    ) async throws -> Bool {
        try await hasOutput(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: "GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C \"$1\" status --porcelain --untracked-files=normal | /usr/bin/wc -c",
            operation: .status
        )
    }

    func hasDeletionChanges(
        commandDirectory: String,
        worktreePath: String
    ) async throws -> Bool {
        try await hasOutput(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: "GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C \"$1\" status --porcelain --untracked-files=all | /usr/bin/wc -c",
            operation: .status
        )
    }

    func hasIgnoredFiles(
        commandDirectory: String,
        worktreePath: String
    ) async throws -> Bool {
        try await hasOutput(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: "GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C \"$1\" ls-files --others --ignored --exclude-standard --directory -z | /usr/bin/wc -c",
            operation: .inspect
        )
    }

    private func hasOutput(
        commandDirectory: String,
        worktreePath: String,
        script: String,
        operation: WorktreeSidebarGitError.Operation
    ) async throws -> Bool {
        let result = await commands.run(
            directory: commandDirectory,
            executable: "/bin/zsh",
            arguments: ["-o", "pipefail", "-c", script, "_", worktreePath],
            timeout: timeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            throw WorktreeSidebarGitError.commandFailed(
                operation,
                details: Self.commandDetails(result)
            )
        }
        let output = (result.stdout ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let byteCount = UInt64(output) else {
            throw WorktreeSidebarGitError.commandFailed(operation, details: output)
        }
        return byteCount > 0
    }

    private static func commandDetails(_ result: CommandResult) -> String {
        [result.stderr, result.stdout, result.executionError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
