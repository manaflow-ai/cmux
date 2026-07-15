import CmuxFoundation
import CmuxGit
import Darwin
import Foundation
import os

nonisolated private let extensionWorktreeLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ExtensionWorktree"
)

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

enum CmuxExtensionWorktreePrototype {
    static func createWorktree(projectRootPath: String) async throws -> CmuxExtensionWorktreeCreationResult {
        let worker = Task.detached(priority: .userInitiated) {
            let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            try await ensureGitRepository(at: projectRoot)
            try Task.checkCancellation()
            try await ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: projectRoot)
            try Task.checkCancellation()

            let branchName = "cmux-sidebar-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
            let worktreeRoot = projectRoot
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            let worktree = worktreeRoot.appendingPathComponent(branchName, isDirectory: true)
            var worktreeCreationStarted = false
            do {
                try Task.checkCancellation()
                worktreeCreationStarted = true
                try await run("git", ["-C", projectRoot.path, "worktree", "add", "-b", branchName, worktree.path, "HEAD"])
                try Task.checkCancellation()
                try writeSampleDevServerFiles(in: worktree, projectName: projectRoot.lastPathComponent)
                let worktreeIncludeDiagnostics = await WorktreeIncludeSyncService().sync(
                    from: projectRoot,
                    to: worktree,
                    excludingRelativePaths: ["cmux-sample-dev"]
                )
                for diagnostic in worktreeIncludeDiagnostics {
                    extensionWorktreeLogger.warning(
                        "worktree include sync warning project=\(projectRoot.path, privacy: .private(mask: .hash)) detail=\(diagnostic, privacy: .private)"
                    )
                }
                try Task.checkCancellation()

                let port = 4_100 + abs(branchName.hashValue % 800)
                let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
                let result = CmuxExtensionWorktreeCreationResult(
                    worktreePath: worktree.path,
                    workspaceTitle: branchName,
                    setupCommand: "cd \(samplePath) && python3 -m http.server \(port)"
                )
                worktreeCreationStarted = false
                return result
            } catch {
                let rollbackSafe = (error as? CmuxExtensionWorktreeCommandFailure)?.rollbackSafe ?? true
                if worktreeCreationStarted, rollbackSafe {
                    await Task.detached(priority: .utility) {
                        await rollbackWorktree(
                            projectRoot: projectRoot,
                            worktree: worktree,
                            branchName: branchName
                        )
                    }.value
                }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
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

    private static func rollbackWorktree(
        projectRoot: URL,
        worktree: URL,
        branchName: String
    ) async {
        do {
            try await run("git", [
                "-C", projectRoot.path,
                "worktree", "remove", "--force", worktree.path,
            ])
        } catch {
            extensionWorktreeLogger.error(
                "worktree rollback removal failed project=\(projectRoot.path, privacy: .private(mask: .hash)) detail=\(error.localizedDescription, privacy: .private)"
            )
        }
        do {
            try await run("git", ["-C", projectRoot.path, "branch", "-D", branchName])
        } catch {
            extensionWorktreeLogger.error(
                "worktree rollback branch deletion failed project=\(projectRoot.path, privacy: .private(mask: .hash)) detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: URL) async throws {
        let output = try await runCapturingOutput("git", ["-C", projectRoot.path, "rev-parse", "--git-path", "info/exclude"])
        let rawPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
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
        let worktreeDescriptor = Darwin.open(
            worktree.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard worktreeDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(worktreeDescriptor) }

        let sampleName = "cmux-sample-dev"
        let createDirectoryResult = sampleName.withCString {
            mkdirat(worktreeDescriptor, $0, 0o700)
        }
        guard createDirectoryResult == 0 || errno == EEXIST else { throw posixError() }
        let sampleDescriptor = sampleName.withCString {
            openat(worktreeDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sampleDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(sampleDescriptor) }

        let temporaryName = ".cmux-index-\(UUID().uuidString)"
        let indexDescriptor = temporaryName.withCString {
            openat(
                sampleDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard indexDescriptor >= 0 else { throw posixError() }
        var installed = false
        defer {
            Darwin.close(indexDescriptor)
            if !installed {
                _ = temporaryName.withCString { unlinkat(sampleDescriptor, $0, 0) }
            }
        }

        let htmlData = Data(html.utf8)
        var written = 0
        while written < htmlData.count {
            let writeCount = htmlData.withUnsafeBytes {
                Darwin.write(
                    indexDescriptor,
                    $0.baseAddress?.advanced(by: written),
                    $0.count - written
                )
            }
            if writeCount == -1, errno == EINTR { continue }
            guard writeCount > 0 else { throw posixError() }
            written += writeCount
        }
        let installResult = temporaryName.withCString { temporaryPointer in
            "index.html".withCString { indexPointer in
                renameat(sampleDescriptor, temporaryPointer, sampleDescriptor, indexPointer)
            }
        }
        guard installResult == 0 else { throw posixError() }
        installed = true
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runCapturingOutput(executable, arguments)
    }

    private static func runCapturingOutput(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = await CommandRunner().run(
            directory: FileManager.default.currentDirectoryPath,
            executable: executable,
            arguments: arguments,
            timeout: nil
        )
        if Task.isCancelled, result.cancellationCleanupSucceeded != false {
            throw CancellationError()
        }
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            let details = result.stderr ?? result.stdout ?? result.executionError ?? "command failed"
            let underlyingError = NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(result.exitStatus ?? -1),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create worktree.",
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
            throw CmuxExtensionWorktreeCommandFailure(
                result: result,
                underlyingError: underlyingError,
                rollbackSafe: result.cancellationCleanupSucceeded != false
            )
        }
        return result.stdout ?? ""
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
