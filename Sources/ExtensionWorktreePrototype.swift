import CmuxFoundation
import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let worktreePath: String
    let workspaceTitle: String
    /// A convenience command (e.g. a sample dev-server launcher) that should run
    /// inside the new workspace's interactive shell. This is *setup*, never the
    /// workspace's primary process.
    let setupCommand: String
}

/// Arguments for spawning a workspace in a freshly created worktree.
///
/// A workspace closes the moment its main process exits, so the worktree
/// `setupCommand` must be delivered as terminal *input* typed into the
/// interactive login shell — never as the surface's primary process. This type
/// deliberately has **no** primary-command field: the workspace's main process
/// is structurally always the login shell, so the "setup command became the
/// main process and the tab died when it exited" bug cannot be expressed here.
struct CmuxExtensionWorktreeWorkspaceSpawnArgs: Sendable, Equatable {
    let title: String
    let workingDirectory: String
    /// Setup command typed into the interactive shell after spawn (with a
    /// trailing newline so it executes), or `nil` when there is no setup.
    let initialTerminalInput: String?
    let inheritWorkingDirectory: Bool
}

extension CmuxExtensionWorktreeCreationResult {
    /// Builds the workspace spawn arguments for this worktree.
    ///
    /// The returned arguments always leave the workspace's main process as the
    /// login shell and deliver ``setupCommand`` as terminal input.
    func workspaceSpawnArgs() -> CmuxExtensionWorktreeWorkspaceSpawnArgs {
        // Worktree creation already ran as a pre-spawn step, so the setup
        // command is delivered as interactive shell input (with a trailing
        // newline so it executes) rather than as the surface's primary process.
        CmuxExtensionWorktreeWorkspaceSpawnArgs(
            title: workspaceTitle,
            workingDirectory: worktreePath,
            initialTerminalInput: setupCommand.isEmpty ? nil : setupCommand + "\n",
            inheritWorkingDirectory: false
        )
    }
}

/// Arguments for opening a terminal workspace inside an *existing* worktree.
///
/// Like ``CmuxExtensionWorktreeWorkspaceSpawnArgs``, this type deliberately has
/// **no** primary-command field: "Open terminal inside" must spawn a stable
/// interactive login shell as the workspace's main process. Routing a one-shot
/// command in as the primary process makes the tab exit the moment the command
/// finishes (https://github.com/manaflow-ai/cmux/issues/5032), so the bug is
/// made structurally unrepresentable by omitting the field entirely.
struct CmuxExtensionWorktreeOpenTerminalArgs: Sendable, Equatable {
    let title: String
    let workingDirectory: String
    let inheritWorkingDirectory: Bool
}

/// A cmux-managed worktree, parsed from a workspace's resolved git-root path.
///
/// The sidebar "+" creates worktrees at `<parentRepo>/.cmux/worktrees/<branch>`,
/// so a git root that contains the `/.cmux/worktrees/` segment identifies a
/// removable, cmux-managed worktree and yields both the worktree path and the
/// parent repository it belongs to.
struct CmuxExtensionWorktreeIdentity: Sendable, Equatable {
    let worktreePath: String
    let parentRepoPath: String
}

/// The result of inspecting a worktree before removal.
///
/// `git worktree remove` preserves the branch (committed work is recoverable
/// from the parent repo), so the only directly destructive case is removing a
/// working tree with **uncommitted** changes — which `git worktree remove`
/// itself refuses without `--force`. Unpushed commits are surfaced as a
/// warning even though removal keeps the branch.
struct CmuxExtensionWorktreeRemovalSafety: Sendable, Equatable {
    var hasUncommittedChanges: Bool
    var unpushedCommitCount: Int
    /// True when the safety probe itself failed (git error / not a worktree).
    /// An unknown state is treated as *not* clean: removal always confirms and
    /// the confirmation can't be suppressed, so a stale "don't ask again"
    /// preference can never skip the prompt for an un-inspected worktree.
    var inspectionFailed: Bool = false

    var hasUnpushedCommits: Bool { unpushedCommitCount > 0 }

    /// Whether the worktree is known to have no unsaved or unpushed work.
    var isClean: Bool { !inspectionFailed && !hasUncommittedChanges && !hasUnpushedCommits }

    /// `git worktree remove` refuses a dirty working tree without `--force`.
    /// An unknown state does *not* force: git is left to refuse a dirty tree.
    var requiresForce: Bool { hasUncommittedChanges }
}

final class CmuxExtensionProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>?
        lock.lock()
        if let pendingContinuation = self.continuation {
            self.continuation = nil
            continuation = pendingContinuation
        } else {
            self.status = status
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32?
            lock.lock()
            if let status {
                completedStatus = status
            } else {
                self.continuation = continuation
                completedStatus = nil
            }
            lock.unlock()

            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }
}

enum CmuxExtensionWorktreePrototype {
    static func createWorktree(projectRootPath: String) async throws -> CmuxExtensionWorktreeCreationResult {
        try await Task.detached(priority: .userInitiated) {
            let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            try await ensureGitRepository(at: projectRoot)
            try await ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: projectRoot)

            let branchName = "cmux-sidebar-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
            let worktreeRoot = projectRoot
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            let worktree = worktreeRoot.appendingPathComponent(branchName, isDirectory: true)
            try await run("git", ["-C", projectRoot.path, "worktree", "add", "-b", branchName, worktree.path, "HEAD"])
            try writeSampleDevServerFiles(in: worktree, projectName: projectRoot.lastPathComponent)

            let port = 4_100 + abs(branchName.hashValue % 800)
            let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
            return CmuxExtensionWorktreeCreationResult(
                worktreePath: worktree.path,
                workspaceTitle: branchName,
                setupCommand: "cd \(samplePath) && python3 -m http.server \(port)"
            )
        }.value
    }

    /// Path segment that marks a cmux-managed worktree container. Worktrees
    /// created by the sidebar "+" live at `<parentRepo>/.cmux/worktrees/<branch>`.
    static let managedWorktreeContainerSegment = "/.cmux/worktrees/"

    /// Builds the spawn arguments for "Open terminal inside" an existing
    /// worktree. The workspace's main process is always the interactive login
    /// shell (no primary command), matching the `cmux new-workspace --cwd`
    /// contract so the tab stays alive after spawn.
    static func openTerminalArgs(worktreePath: String) -> CmuxExtensionWorktreeOpenTerminalArgs {
        let url = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
        let name = url.lastPathComponent
        return CmuxExtensionWorktreeOpenTerminalArgs(
            title: name.isEmpty ? url.path : name,
            workingDirectory: url.path,
            inheritWorkingDirectory: false
        )
    }

    /// Parses a cmux-managed worktree identity from a workspace's resolved
    /// git-root path, or `nil` when the path is not a managed worktree (e.g. a
    /// plain project checkout). Pure and synchronous so it is cheap to call at
    /// the row-render site.
    static func managedWorktreeIdentity(gitRootPath: String?) -> CmuxExtensionWorktreeIdentity? {
        guard let raw = gitRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let standardized = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        guard let range = standardized.range(of: managedWorktreeContainerSegment) else { return nil }
        let parent = String(standardized[..<range.lowerBound])
        let remainder = standardized[range.upperBound...]
        // Require a non-empty parent repo and a non-empty worktree name segment.
        guard !parent.isEmpty, !remainder.isEmpty else { return nil }
        return CmuxExtensionWorktreeIdentity(worktreePath: standardized, parentRepoPath: parent)
    }

    /// Pure decision: whether removing a worktree should prompt for
    /// confirmation. A worktree with unsaved or unpushed work *always* prompts,
    /// regardless of the "don't ask again" suppression flag, so suppression can
    /// never silently destroy work.
    static func removalRequiresConfirmation(
        safety: CmuxExtensionWorktreeRemovalSafety,
        suppressionEnabled: Bool
    ) -> Bool {
        if !safety.isClean { return true }
        return !suppressionEnabled
    }

    /// Pure selection of the workspace ids physically inside the given worktree
    /// path. Used to close every workspace tab rooted in a worktree when it is
    /// removed (the original "+" tab plus any "Open terminal inside" tabs).
    ///
    /// Matching is by containment of each workspace's *live current directory*
    /// (its actual reported cwd) rather than the asynchronously-derived,
    /// possibly-stale `extensionSidebarProjectRootPath`, so a destructive
    /// removal operates on authoritative state. Input order is preserved so
    /// callers close tabs deterministically.
    static func workspaceIdsRooted(
        inWorktreePath worktreePath: String,
        workspaces: [(id: UUID, currentDirectory: String?)]
    ) -> [UUID] {
        let target = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path
        let prefix = target + "/"
        return workspaces.compactMap { entry in
            guard let directory = entry.currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !directory.isEmpty else {
                return nil
            }
            let standardized = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
            return (standardized == target || standardized.hasPrefix(prefix)) ? entry.id : nil
        }
    }

    /// Pure decision: whether closing `closingCount` workspaces would empty the
    /// window. `TabManager.closeWorkspace` refuses to close the last workspace,
    /// so when removal would close every tab the caller must spawn a live
    /// replacement first — otherwise the final tab lingers over the deleted
    /// worktree directory.
    static func replacementWorkspaceNeeded(totalWorkspaceCount: Int, closingCount: Int) -> Bool {
        closingCount > 0 && closingCount >= totalWorkspaceCount
    }

    /// Inspects a worktree for unsaved/unpushed work before removal.
    static func inspectRemovalSafety(worktreePath: String) async throws -> CmuxExtensionWorktreeRemovalSafety {
        try await Task.detached(priority: .userInitiated) {
            let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path

            let statusOutput = try await runGitTrimmed(
                ["-C", worktree, "status", "--porcelain"],
                failureDescription: "Could not inspect the worktree status."
            )
            let hasUncommittedChanges = !statusOutput.isEmpty

            // Unpushed = commits on HEAD not reachable from any remote-tracking
            // branch. Skip when the repo has no remotes at all, since
            // `rev-list --not --remotes` would otherwise count the entire
            // history and over-report a local-only repo as "unpushed".
            let remotes = try await runGitTrimmed(
                ["-C", worktree, "remote"],
                failureDescription: "Could not list git remotes."
            )
            var unpushedCommitCount = 0
            if !remotes.isEmpty {
                let revOutput = try await runGitTrimmed(
                    ["-C", worktree, "rev-list", "--count", "HEAD", "--not", "--remotes"],
                    failureDescription: "Could not count unpushed commits."
                )
                unpushedCommitCount = Int(revOutput) ?? 0
            }

            return CmuxExtensionWorktreeRemovalSafety(
                hasUncommittedChanges: hasUncommittedChanges,
                unpushedCommitCount: unpushedCommitCount
            )
        }.value
    }

    /// Removes a worktree: `git worktree remove` (with `--force` only when the
    /// caller authorized destroying uncommitted changes) followed by
    /// `git worktree prune` in the parent repository. The branch is left
    /// intact — `git worktree remove` only deletes the working directory, so
    /// committed work stays recoverable from the branch, matching the
    /// confirmation copy. Branch deletion is intentionally not performed here.
    static func removeWorktree(worktreePath: String, force: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path

            // Resolve the parent repository from the shared common dir so the
            // prune/branch cleanup run against the main working tree regardless
            // of the on-disk worktree layout.
            var commonDir = (try? await runGitTrimmed(
                ["-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                failureDescription: ""
            )) ?? ""
            if commonDir.isEmpty {
                // Older git lacks `--path-format`; fall back to the raw value
                // and resolve it relative to the worktree when it is relative.
                let raw = try await runGitTrimmed(
                    ["-C", worktree, "rev-parse", "--git-common-dir"],
                    failureDescription: "Could not resolve the parent repository."
                )
                commonDir = raw.hasPrefix("/")
                    ? raw
                    : URL(fileURLWithPath: worktree, isDirectory: true)
                        .appendingPathComponent(raw)
                        .standardizedFileURL.path
            }
            let parentRepo = URL(fileURLWithPath: commonDir, isDirectory: true)
                .deletingLastPathComponent()
                .standardizedFileURL.path

            var removeArgs = ["-C", parentRepo, "worktree", "remove"]
            if force { removeArgs.append("--force") }
            removeArgs.append(worktree)
            _ = try await runGitTrimmed(removeArgs, failureDescription: "Could not remove the worktree.")

            // Prune stale administrative entries in the parent repository.
            // The branch itself is deliberately NOT deleted: the confirmation
            // promises committed work on the branch is kept, so removal only
            // ever discards the working directory (and uncommitted changes when
            // forced). Branch cleanup, if ever wanted, must be its own
            // explicitly-confirmed action.
            _ = await runAllowingFailure(["-C", parentRepo, "worktree", "prune"])
        }.value
    }

    private static func ensureGitRepository(at projectRoot: URL) async throws {
        if (try? await run("git", ["-C", projectRoot.path, "rev-parse", "--is-inside-work-tree"])) != nil {
            return
        }
        throw NSError(
            domain: "CmuxExtensionWorktreePrototype",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Project root is not a git repository."]
        )
    }

    private static func ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: URL) async throws {
        let output = try await runCapturingOutput("git", ["-C", projectRoot.path, "rev-parse", "--git-path", "info/exclude"])
        guard let rawPath = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve git exclude file."]
            )
        }

        let excludeURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : projectRoot.appendingPathComponent(rawPath).standardizedFileURL
        try FileManager.default.createDirectory(at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let alreadyIgnored = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0 == ".cmux" || $0 == ".cmux/" }
        guard !alreadyIgnored else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let next = existing + separator + "# cmux extension worktrees\n.cmux/\n"
        try next.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private static func writeSampleDevServerFiles(in worktree: URL, projectName: String) throws {
        let sample = worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let escapedProject = projectName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>cmux worktree</title></head>
          <body style="font: 15px -apple-system; padding: 32px;">
            <h1>\(escapedProject) worktree</h1>
            <p>This page is served from a git worktree created by CmuxExtensionKit.</p>
          </body>
        </html>
        """
        try html.write(to: sample.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runCapturingOutput(executable, arguments)
    }

    private static func runCapturingOutput(
        _ executable: String,
        _ arguments: [String],
        failureDescription: String = "Could not create worktree."
    ) async throws -> Data {
        let result = await runProcess(executable, arguments)
        guard result.status == 0 else {
            let details = String(data: result.output, encoding: .utf8) ?? "command failed"
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(result.status),
                userInfo: [
                    NSLocalizedDescriptionKey: failureDescription.isEmpty
                        ? "Git command failed."
                        : failureDescription,
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
        }
        return result.output
    }

    /// Runs `git` and returns its trimmed stdout/stderr, throwing on a non-zero
    /// exit with `failureDescription` as the user-facing message.
    @discardableResult
    private static func runGitTrimmed(
        _ arguments: [String],
        failureDescription: String
    ) async throws -> String {
        let data = try await runCapturingOutput("git", arguments, failureDescription: failureDescription)
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `git` without throwing, returning the exit status and trimmed
    /// output. Used for best-effort cleanup (prune, branch -d) and optional
    /// probes (current branch) where a non-zero exit is expected and benign.
    private static func runAllowingFailure(_ arguments: [String]) async -> (status: Int32, stdout: String) {
        let result = await runProcess("git", arguments)
        let text = (String(data: result.output, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status, text)
    }

    private static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) async -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let termination = CmuxExtensionProcessTermination()
        process.terminationHandler = { process in
            termination.complete(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            return (-1, Data((error.localizedDescription).utf8))
        }
        let outputCollector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)
        let terminationStatus = await termination.wait()
        let outputData = await outputCollector.finish()
        return (terminationStatus, outputData)
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class CmuxExtensionPipeOutputCollector: @unchecked Sendable {
    private struct ReadHandle: @unchecked Sendable {
        let fileHandle: FileHandle
    }

    private let readTask: Task<Data, Never>

    init(fileHandle: FileHandle) {
        let readHandle = ReadHandle(fileHandle: fileHandle)
        readTask = Task.detached(priority: .utility) {
            let data = readHandle.fileHandle.readDataToEndOfFileOrEmpty()
            try? readHandle.fileHandle.close()
            return data
        }
    }

    func finish() async -> Data {
        await readTask.value
    }
}
