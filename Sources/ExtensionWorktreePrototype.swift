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
/// removable, cmux-managed worktree. Nested git roots under that directory still
/// resolve to the first-level managed worktree path and its parent repository.
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
    var hasUnreferencedDetachedHead: Bool = false
    /// True when the safety probe itself failed (git error / not a worktree).
    /// An unknown state is treated as *not* clean so the prompt uses the
    /// stronger warning copy and git still gets the final say on removal.
    var inspectionFailed: Bool = false

    var hasUnpushedCommits: Bool { unpushedCommitCount > 0 }

    /// Whether the worktree is known to have no unsaved or unpushed work.
    var isClean: Bool {
        !inspectionFailed
            && !hasUncommittedChanges
            && !hasUnpushedCommits
            && !hasUnreferencedDetachedHead
    }

    /// `git worktree remove` refuses a dirty working tree without `--force`.
    /// An unknown state does *not* force: git is left to refuse a dirty tree.
    var requiresForce: Bool { hasUncommittedChanges }
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

    /// Parses the innermost cmux-managed worktree identity from a workspace's
    /// resolved git-root path, or `nil` when the path is not a managed worktree
    /// (e.g. a plain project checkout). Pure and synchronous so it is cheap to
    /// call at the row-render site.
    static func managedWorktreeIdentity(gitRootPath: String?) -> CmuxExtensionWorktreeIdentity? {
        guard let raw = gitRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let standardized = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        guard let range = standardized.range(of: managedWorktreeContainerSegment, options: .backwards) else { return nil }
        let parent = String(standardized[..<range.lowerBound])
        let remainder = standardized[range.upperBound...]
        // Require a non-empty parent repo and a non-empty worktree name segment.
        guard !parent.isEmpty,
              let worktreeName = remainder.split(separator: "/", maxSplits: 1).first,
              !worktreeName.isEmpty else {
            return nil
        }
        let worktreePath = parent + managedWorktreeContainerSegment + String(worktreeName)
        return CmuxExtensionWorktreeIdentity(worktreePath: worktreePath, parentRepoPath: parent)
    }

    /// Pure selection of the workspace ids physically inside the given worktree
    /// path. Used to close every workspace tab rooted in a worktree when it is
    /// removed (the original "+" tab plus any "Open terminal inside" tabs).
    ///
    /// Matching is by containment of each workspace's live directory candidates
    /// (workspace cwd plus panel-local directories) rather than the
    /// asynchronously-derived, possibly-stale `extensionSidebarProjectRootPath`,
    /// so a destructive removal operates on authoritative state. Input order is
    /// preserved so callers close tabs deterministically.
    static func workspaceIdsRooted(
        inWorktreePath worktreePath: String,
        workspaces: [(id: UUID, candidateDirectories: [String?])]
    ) -> [UUID] {
        let target = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path
        let prefix = target + "/"
        return workspaces.compactMap { entry in
            let isRooted = entry.candidateDirectories.contains { candidate in
                guard let directory = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !directory.isEmpty else {
                    return false
                }
                let standardized = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
                return standardized == target || standardized.hasPrefix(prefix)
            }
            return isRooted ? entry.id : nil
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

            let hasUncommittedChanges = try await hasWorktreeChanges(worktree: worktree)

            var hasUnreferencedDetachedHead = false
            let headBranch = await runAllowingFailure(["-C", worktree, "symbolic-ref", "--quiet", "--short", "HEAD"])
            if headBranch.status != 0 {
                let localRefsContainingHead = try await runGitTrimmed(
                    ["-C", worktree, "for-each-ref", "--count=1", "--contains", "HEAD", "--format=%(refname)", "refs/heads", "refs/tags"],
                    failureDescription: errorDescription("extensionWorktree.error.inspectLocalRefs", "Could not inspect local refs containing HEAD.")
                )
                hasUnreferencedDetachedHead = localRefsContainingHead.isEmpty
            }

            // Unpushed = commits on HEAD not reachable from any remote-tracking
            // branch. Skip when the repo has no remote-tracking refs, since a
            // template/global-configured remote with no fetched refs makes
            // `rev-list --not --remotes` count the entire local history.
            let remoteRefs = try await runGitTrimmed(
                ["-C", worktree, "for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes"],
                failureDescription: errorDescription("extensionWorktree.error.listRemoteRefs", "Could not list git remote refs.")
            )
            var unpushedCommitCount = 0
            if !remoteRefs.isEmpty {
                let revOutput = try await runGitTrimmed(
                    ["-C", worktree, "rev-list", "--count", "HEAD", "--not", "--remotes"],
                    failureDescription: errorDescription("extensionWorktree.error.unpushedCommitCount", "Could not count unpushed commits.")
                )
                unpushedCommitCount = Int(revOutput) ?? 0
            }

            return CmuxExtensionWorktreeRemovalSafety(
                hasUncommittedChanges: hasUncommittedChanges,
                unpushedCommitCount: unpushedCommitCount,
                hasUnreferencedDetachedHead: hasUnreferencedDetachedHead
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
            guard let identity = managedWorktreeIdentity(gitRootPath: worktree) else {
                throw NSError(
                    domain: "CmuxExtensionWorktreePrototype",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: errorDescription("extensionWorktree.error.parentRepository", "Could not resolve the parent repository.")]
                )
            }
            let parentRepo = identity.parentRepoPath
            let worktreeToRemove = identity.worktreePath

            var removeArgs = ["-C", parentRepo, "worktree", "remove"]
            if force { removeArgs.append("--force") }
            removeArgs.append(worktreeToRemove)
            _ = try await runGitTrimmed(
                removeArgs,
                failureDescription: errorDescription("extensionWorktree.error.remove", "Could not remove the worktree.")
            )

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
            userInfo: [NSLocalizedDescriptionKey: errorDescription("extensionWorktree.error.projectRootNotGitRepository", "Project root is not a git repository.")]
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
                userInfo: [NSLocalizedDescriptionKey: errorDescription("extensionWorktree.error.gitExcludeFile", "Could not resolve git exclude file.")]
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

    /// Bounded dirty check: use git exit statuses and discard command output so
    /// the removal confirmation path cannot allocate for every changed file.
    private static func hasWorktreeChanges(worktree: String) async throws -> Bool {
        let trackedStatus = await runGitExitStatusDiscardingOutput(
            ["-C", worktree, "diff-index", "--quiet", "HEAD", "--"]
        )
        if trackedStatus == 1 { return true }
        if trackedStatus != 0 {
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(trackedStatus),
                userInfo: [NSLocalizedDescriptionKey: errorDescription("extensionWorktree.error.inspectTrackedChanges", "Could not inspect tracked changes.")]
            )
        }

        let untrackedStatus = await runGitExitStatusDiscardingOutput(
            ["-C", worktree, "ls-files", "--others", "--exclude-standard", "--directory", "--no-empty-directory", "--error-unmatch", "."]
        )
        if untrackedStatus == 0 { return true }
        if untrackedStatus == 1 { return false }
        throw NSError(
            domain: "CmuxExtensionWorktreePrototype",
            code: Int(untrackedStatus),
            userInfo: [NSLocalizedDescriptionKey: errorDescription("extensionWorktree.error.inspectUntrackedFiles", "Could not inspect untracked files.")]
        )
    }

    private static func runCapturingOutput(
        _ executable: String,
        _ arguments: [String],
        failureDescription: String? = nil
    ) async throws -> Data {
        let result = await runProcess(executable, arguments)
        guard result.status == 0 else {
            var output = result.stdout
            output.append(result.stderr)
            let details = String(data: output, encoding: .utf8) ?? errorDescription("extensionWorktree.error.commandFailedDetails", "Command failed.")
            let description = failureDescription ?? errorDescription("extensionWorktree.error.create", "Could not create worktree.")
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(result.status),
                userInfo: [
                    NSLocalizedDescriptionKey: description.isEmpty
                        ? errorDescription("extensionWorktree.error.gitCommandFailed", "Git command failed.")
                        : description,
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
        }
        return result.stdout
    }

    /// Runs `git` and returns its trimmed stdout, throwing on a non-zero exit
    /// with `failureDescription` as the user-facing message.
    @discardableResult
    private static func runGitTrimmed(
        _ arguments: [String],
        failureDescription: String
    ) async throws -> String {
        let data = try await runCapturingOutput("git", arguments, failureDescription: failureDescription)
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorDescription(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String { String(localized: key, defaultValue: defaultValue) }

    /// Runs `git` without throwing, returning the exit status and trimmed stdout.
    /// Used for best-effort cleanup (prune, branch -d) and optional probes
    /// (current branch) where a non-zero exit is expected and benign.
    private static func runAllowingFailure(_ arguments: [String]) async -> (status: Int32, stdout: String) {
        let result = await runProcess("git", arguments)
        let text = (String(data: result.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status, text)
    }

    private static func runGitExitStatusDiscardingOutput(_ arguments: [String]) async -> Int32 {
        await runProcessDiscardingOutput("git", arguments)
    }

    private static func runProcessDiscardingOutput(_ executable: String, _ arguments: [String]) async -> Int32 {
        guard let stdout = FileHandle(forWritingAtPath: "/dev/null"),
              let stderr = FileHandle(forWritingAtPath: "/dev/null") else {
            return -1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let terminationStream = processTerminationStream(for: process)
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            return -1
        }
        let terminationStatus = await processTerminationStatus(from: terminationStream)
        try? stdout.close()
        try? stderr.close()
        return terminationStatus
    }

    private static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) async -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let terminationStream = processTerminationStream(for: process)
        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            return (-1, Data(), Data((error.localizedDescription).utf8))
        }
        let stdoutCollector = CmuxExtensionPipeOutputCollector(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrCollector = CmuxExtensionPipeOutputCollector(fileHandle: stderrPipe.fileHandleForReading)
        let terminationStatus = await processTerminationStatus(from: terminationStream)
        let stdoutData = await stdoutCollector.finish()
        let stderrData = await stderrCollector.finish()
        return (terminationStatus, stdoutData, stderrData)
    }

    private static func processTerminationStream(for process: Process) -> AsyncStream<Int32> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.yield(finishedProcess.terminationStatus)
                continuation.finish()
            }
        }
    }

    private static func processTerminationStatus(from stream: AsyncStream<Int32>) async -> Int32 {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? -1
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
