import CmuxFoundation
import Foundation

/// Runs worktree risk probes without retaining path-sized Git output in cmux.
struct WorktreeSidebarBoundedGitProbe: Sendable {
    struct Fingerprint: Equatable, Sendable {
        static let empty = Fingerprint(
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        let sha256: String

        var hasContent: Bool { self != .empty }
    }

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

    func deletionChangesFingerprint(
        commandDirectory: String,
        worktreePath: String
    ) async throws -> Fingerprint {
        try await fingerprint(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: "GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C \"$1\" status --porcelain --untracked-files=all | /usr/bin/shasum -a 256",
            operation: .status
        )
    }

    func ignoredFilesFingerprint(
        commandDirectory: String,
        worktreePath: String
    ) async throws -> Fingerprint {
        try await fingerprint(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: "GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C \"$1\" ls-files --others --ignored --exclude-standard -z | /usr/bin/shasum -a 256",
            operation: .inspect
        )
    }

    private func fingerprint(
        commandDirectory: String,
        worktreePath: String,
        script: String,
        operation: WorktreeSidebarGitError.Operation
    ) async throws -> Fingerprint {
        let output = try await boundedOutput(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: script,
            operation: operation
        )
        guard let digest = output.split(whereSeparator: \.isWhitespace).first,
              digest.count == 64,
              digest.allSatisfy(\.isHexDigit) else {
            throw WorktreeSidebarGitError.commandFailed(operation, details: output)
        }
        return Fingerprint(sha256: String(digest).lowercased())
    }

    private func hasOutput(
        commandDirectory: String,
        worktreePath: String,
        script: String,
        operation: WorktreeSidebarGitError.Operation
    ) async throws -> Bool {
        let output = try await boundedOutput(
            commandDirectory: commandDirectory,
            worktreePath: worktreePath,
            script: script,
            operation: operation
        )
        guard let byteCount = UInt64(output) else {
            throw WorktreeSidebarGitError.commandFailed(operation, details: output)
        }
        return byteCount > 0
    }

    private func boundedOutput(
        commandDirectory: String,
        worktreePath: String,
        script: String,
        operation: WorktreeSidebarGitError.Operation
    ) async throws -> String {
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
        return output
    }

    private static func commandDetails(_ result: CommandResult) -> String {
        [result.stderr, result.stdout, result.executionError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
