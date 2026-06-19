import Foundation

/// Provisions one isolated git worktree per Kanban card, so concurrently
/// dispatched agents never collide in the same working tree.
///
/// Best-effort and self-degrading: if `repoRoot` is not inside a git
/// repository, or `git worktree add` fails, ``provision(cardId:repoRoot:)``
/// returns `nil` and the caller runs the agent in the workspace directory
/// directly. The provisioner shells out to `git` via `Process`; each call is a
/// short, low-output command, so reading the pipe after exit cannot deadlock.
actor GitWorktreeProvisioner {
    /// A provisioned worktree: where it lives and the branch checked out in it.
    struct Provisioned: Sendable, Equatable {
        let worktreePath: String
        let branchName: String
    }

    /// Directory under which per-card worktrees are created
    /// (`<baseDirectory>/<cardId>`).
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    /// Creates a worktree for `cardId` off the repository containing `repoRoot`.
    ///
    /// - Returns: the worktree path and branch, or `nil` if `repoRoot` is not a
    ///   git repo or the worktree could not be created (caller should fall back
    ///   to running in `repoRoot`).
    func provision(cardId: UUID, repoRoot: String) async -> Provisioned? {
        let top = await git(["-C", repoRoot, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else { return nil }
        let toplevel = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toplevel.isEmpty else { return nil }

        let worktreeURL = baseDirectory.appendingPathComponent(cardId.uuidString, isDirectory: true)
        // A fresh path is required; if one is left over from a prior run, reuse it.
        if fileManager.fileExists(atPath: worktreeURL.path) {
            let branch = "cmux/kanban/\(cardId.uuidString.prefix(8))"
            return Provisioned(worktreePath: worktreeURL.path, branchName: String(branch))
        }
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let branch = "cmux/kanban/\(cardId.uuidString.prefix(8))"
        let add = await git(["-C", toplevel, "worktree", "add", worktreeURL.path, "-b", String(branch)])
        guard add.status == 0 else { return nil }
        return Provisioned(worktreePath: worktreeURL.path, branchName: String(branch))
    }

    /// Removes a card's worktree (best-effort; ignores failure).
    func teardown(cardId: UUID, repoRoot: String) async {
        let worktreeURL = baseDirectory.appendingPathComponent(cardId.uuidString, isDirectory: true)
        _ = await git(["-C", repoRoot, "worktree", "remove", "--force", worktreeURL.path])
    }

    private func git(_ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            process.terminationHandler = { finished in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, ""))
            }
        }
    }
}
