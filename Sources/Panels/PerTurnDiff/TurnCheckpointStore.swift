import Foundation

/// Stateless wrapper for git plumbing operations used by the per-turn diff snapshotting.
/// Uses /usr/bin/git shell-out (matches existing pattern in Sources/FileExplorerStore.swift:958).
enum TurnCheckpointStore {
    enum Error: Swift.Error {
        case gitFailed(stderr: String, exitCode: Int32)
        case unexpectedOutput(String)
    }

    // MARK: - Path helpers

    static func gitCommonDir(for worktree: String) -> String? {
        try? runGit(in: worktree, arguments: ["rev-parse", "--git-common-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Snapshot operations

    /// Stages all current worktree contents (including untracked, respecting .gitignore)
    /// into an isolated index file, then writes the tree object. Returns the tree SHA.
    /// The user's real .git/index is never touched.
    @discardableResult
    static func writeTreeIsolated(in worktree: String) throws -> String {
        let indexPath = NSString.path(withComponents: [
            NSTemporaryDirectory(),
            "cmux-pertd-\(UUID().uuidString).idx"
        ])
        defer { try? FileManager.default.removeItem(atPath: indexPath) }
        let env = ["GIT_INDEX_FILE": indexPath]
        _ = try runGit(in: worktree, arguments: ["add", "-A"], env: env)
        let tree = try runGit(in: worktree, arguments: ["write-tree"], env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.count == 40 else { throw Error.unexpectedOutput("write-tree returned: \(tree)") }
        return tree
    }

    /// Builds a commit object with the given tree and parent. Returns the commit SHA.
    static func commitTree(_ tree: String, parent: String, message: String, in worktree: String) throws -> String {
        let env: [String: String] = [
            "GIT_AUTHOR_NAME": "cmux", "GIT_AUTHOR_EMAIL": "cmux@local",
            "GIT_COMMITTER_NAME": "cmux", "GIT_COMMITTER_EMAIL": "cmux@local"
        ]
        let commit = try runGit(
            in: worktree,
            arguments: ["commit-tree", tree, "-p", parent, "-m", message],
            env: env
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40 else { throw Error.unexpectedOutput("commit-tree returned: \(commit)") }
        return commit
    }

    static func refName(for session: UUID) -> String {
        "refs/cmux/session-\(session.uuidString.lowercased())/last-turn-base"
    }

    static func updateRef(session: UUID, commit: String, in worktree: String) throws {
        _ = try runGit(in: worktree, arguments: ["update-ref", refName(for: session), commit])
    }

    static func cleanup(session: UUID, in worktree: String) throws {
        _ = try runGit(in: worktree, arguments: ["update-ref", "-d", refName(for: session)])
    }

    // MARK: - Diff queries

    /// Diff between session's last-turn-base ref and the working tree.
    /// Returns unified diff text suitable for diff2html.
    static func diffAgainstWorkingTree(session: UUID, in worktree: String) throws -> String {
        try runGit(
            in: worktree,
            arguments: [
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--unified=3",
                refName(for: session)
            ]
        )
    }

    // MARK: - runGit

    @discardableResult
    private static func runGit(
        in directory: String,
        arguments: [String],
        env: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        if !env.isEmpty {
            var combined = ProcessInfo.processInfo.environment
            for (k, v) in env { combined[k] = v }
            process.environment = combined
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw Error.gitFailed(stderr: err, exitCode: process.terminationStatus)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
