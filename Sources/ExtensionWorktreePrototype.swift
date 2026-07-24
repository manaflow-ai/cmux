import CmuxFoundation
import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let projectRootPath: String
    let worktreePath: String
    let branchName: String
    let workspaceTitle: String
    let createdHead: String
    let generatedArtifactRelativePath: String
    let generatedArtifactContents: Data
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

    /// Removes this newly created worktree and its owned branch when workspace
    /// admission fails before anything can use them.
    func rollbackUnclaimedWorktree() async throws {
        try await Task.detached(priority: .utility) {
            let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
            let projectRootURL = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
            let artifactURL = worktreeURL
                .appendingPathComponent(generatedArtifactRelativePath, isDirectory: false)
                .standardizedFileURL
            let worktreePrefix = worktreeURL.path.hasSuffix("/") ? worktreeURL.path : worktreeURL.path + "/"
            guard artifactURL.path.hasPrefix(worktreePrefix),
                  !generatedArtifactRelativePath.hasPrefix("/") else {
                throw rollbackRefused("Generated artifact path escaped the worktree.")
            }

            let topLevelData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "rev-parse", "--show-toplevel"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let topLevel = String(decoding: topLevelData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == worktreeURL.path else {
                throw rollbackRefused("Worktree path no longer identifies the created checkout.")
            }

            let branchRef = "refs/heads/\(branchName)"
            let checkedOutBranchData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "symbolic-ref", "--quiet", "HEAD"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let checkedOutBranch = String(decoding: checkedOutBranchData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard checkedOutBranch == branchRef else {
                throw rollbackRefused("Worktree branch changed after creation.")
            }

            let worktreeHeadData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "rev-parse", "--verify", "HEAD"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let worktreeHead = String(decoding: worktreeHeadData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let branchHeadData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", projectRootURL.path, "rev-parse", "--verify", branchRef],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let branchHead = String(decoding: branchHeadData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard worktreeHead == createdHead, branchHead == createdHead else {
                throw rollbackRefused("Worktree or branch HEAD changed after creation.")
            }

            let trackedStatus = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignored=no"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            guard trackedStatus.isEmpty else {
                throw rollbackRefused("Tracked or staged worktree content changed after creation.")
            }

            let untrackedData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "ls-files", "--others", "--exclude-standard", "-z"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let ignoredData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let untrackedPaths = String(decoding: untrackedData, as: UTF8.self)
                .split(separator: "\0")
                .map(String.init)
            let ignoredPaths = String(decoding: ignoredData, as: UTF8.self)
                .split(separator: "\0")
                .map(String.init)
            guard (untrackedPaths + ignoredPaths).sorted() == [generatedArtifactRelativePath] else {
                throw rollbackRefused("Untracked or ignored worktree content changed after creation.")
            }

            let artifactValues = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard artifactValues.isRegularFile == true,
                  artifactValues.isSymbolicLink != true,
                  try Data(contentsOf: artifactURL) == generatedArtifactContents else {
                throw rollbackRefused("Generated artifact changed after creation.")
            }
            let artifactDirectory = artifactURL.deletingLastPathComponent()
            let artifactDirectoryEntries = try FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path)
            guard artifactDirectoryEntries == [artifactURL.lastPathComponent] else {
                throw rollbackRefused("Generated artifact directory contains other content.")
            }

            let worktreeLockPathData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "git",
                ["-C", worktreeURL.path, "rev-parse", "--git-path", "locked"],
                failureDescription: "Could not remove the unclaimed worktree."
            )
            let worktreeLockPath = String(decoding: worktreeLockPathData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !worktreeLockPath.isEmpty else {
                throw rollbackRefused("Could not resolve the worktree lock path.")
            }
            let worktreeLockURL = worktreeLockPath.hasPrefix("/")
                ? URL(fileURLWithPath: worktreeLockPath).standardizedFileURL
                : worktreeURL.appendingPathComponent(worktreeLockPath).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: worktreeLockURL.path) else {
                throw rollbackRefused("Worktree is locked.")
            }

            let artifactBackupURL = worktreeURL
                .deletingLastPathComponent()
                .appendingPathComponent(".cmux-rollback-\(UUID().uuidString)", isDirectory: false)
            try FileManager.default.moveItem(at: artifactURL, to: artifactBackupURL)

            do {
                try await CmuxExtensionWorktreePrototype.run(
                    "rmdir",
                    [artifactDirectory.path],
                    failureDescription: "Could not remove the unclaimed worktree."
                )
                try await CmuxExtensionWorktreePrototype.run(
                    "git",
                    ["-C", projectRootURL.path, "worktree", "remove", worktreeURL.path],
                    failureDescription: "Could not remove the unclaimed worktree."
                )
                try await CmuxExtensionWorktreePrototype.run(
                    "git",
                    ["-C", projectRootURL.path, "update-ref", "-d", branchRef, createdHead],
                    failureDescription: "Could not delete the unclaimed worktree branch."
                )
            } catch let cleanupError {
                guard FileManager.default.fileExists(atPath: worktreeURL.path) else {
                    throw rollbackRefused(
                        "Cleanup failed after checkout removal; generated artifact retained at "
                            + artifactBackupURL.path + ". " + cleanupError.localizedDescription
                    )
                }

                do {
                    try restoreGeneratedArtifact(from: artifactBackupURL, to: artifactURL)
                } catch let restoreError {
                    throw rollbackRefused(
                        "Cleanup failed and generated artifact could not be restored; backup retained at "
                            + artifactBackupURL.path + ". " + restoreError.localizedDescription
                    )
                }
                throw cleanupError
            }

            try FileManager.default.removeItem(at: artifactBackupURL)
        }.value
    }

    private func restoreGeneratedArtifact(from backupURL: URL, to artifactURL: URL) throws {
        let backupValues = try backupURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard backupValues.isRegularFile == true,
              backupValues.isSymbolicLink != true,
              try Data(contentsOf: backupURL) == generatedArtifactContents else {
            throw rollbackRefused("Generated artifact backup changed before it could be restored.")
        }

        let artifactDirectory = artifactURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: artifactDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw rollbackRefused("Generated artifact directory could not be restored.")
            }
        } else {
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.moveItem(at: backupURL, to: artifactURL)
    }

    private func rollbackRefused(_ details: String) -> NSError {
        NSError(
            domain: "CmuxExtensionWorktreePrototype",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not remove the unclaimed worktree.",
                "CmuxExtensionWorktreePrototypeDetails": details,
            ]
        )
    }
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
            let createdHeadData = try await runCapturingOutput(
                "git",
                ["-C", worktree.path, "rev-parse", "--verify", "HEAD"]
            )
            let createdHead = String(decoding: createdHeadData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !createdHead.isEmpty else {
                throw NSError(
                    domain: "CmuxExtensionWorktreePrototype",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create worktree."]
                )
            }
            let generatedArtifact = try writeSampleDevServerFiles(
                in: worktree,
                projectName: projectRoot.lastPathComponent
            )

            let port = 4_100 + abs(branchName.hashValue % 800)
            let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
            return CmuxExtensionWorktreeCreationResult(
                projectRootPath: projectRoot.path,
                worktreePath: worktree.path,
                branchName: branchName,
                workspaceTitle: branchName,
                createdHead: createdHead,
                generatedArtifactRelativePath: generatedArtifact.relativePath,
                generatedArtifactContents: generatedArtifact.contents,
                setupCommand: "cd \(samplePath) && python3 -m http.server \(port)"
            )
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

    private static func writeSampleDevServerFiles(
        in worktree: URL,
        projectName: String
    ) throws -> (relativePath: String, contents: Data) {
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
        let contents = Data(html.utf8)
        let relativePath = "cmux-sample-dev/index.html"
        try contents.write(
            to: worktree.appendingPathComponent(relativePath, isDirectory: false),
            options: .atomic
        )
        return (relativePath, contents)
    }

    fileprivate static func run(
        _ executable: String,
        _ arguments: [String],
        failureDescription: String = "Could not create worktree."
    ) async throws {
        _ = try await runCapturingOutput(
            executable,
            arguments,
            failureDescription: failureDescription
        )
    }

    fileprivate static func runCapturingOutput(
        _ executable: String,
        _ arguments: [String],
        failureDescription: String = "Could not create worktree."
    ) async throws -> Data {
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
        try process.run()
        let outputCollector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)
        let terminationStatus = await termination.wait()
        let outputData = await outputCollector.finish()
        guard terminationStatus == 0 else {
            let details = String(data: outputData, encoding: .utf8) ?? "command failed"
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: failureDescription,
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
        }
        return outputData
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
