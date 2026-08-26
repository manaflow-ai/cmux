import CmuxFoundation
import Foundation
import OSLog

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let projectRootPath: String
    let worktreePath: String
    let branchName: String
    let workspaceTitle: String
    let createdHead: String
    let generatedArtifactRelativePath: String
    let generatedArtifactContents: Data
    /// Filesystem identity captured immediately after `git worktree add`.
    /// Rollback refuses to touch a path whose checkout was replaced.
    let worktreeDeviceID: UInt64? = nil
    let worktreeFileID: UInt64? = nil
    /// A convenience command (e.g. a sample dev-server launcher) that should run
    /// inside the new workspace's interactive shell. This is *setup*, never the
    /// workspace's primary process.
    let setupCommand: String

    /// Keeps the optional filesystem identity labels available on every toolchain.
    /// Swift omits stored properties with default values from a synthesized
    /// memberwise initializer, which would otherwise drop the rollback identity.
    init(
        projectRootPath: String,
        worktreePath: String,
        branchName: String,
        workspaceTitle: String,
        createdHead: String,
        generatedArtifactRelativePath: String,
        generatedArtifactContents: Data,
        worktreeDeviceID: UInt64? = nil,
        worktreeFileID: UInt64? = nil,
        setupCommand: String
    ) {
        self.projectRootPath = projectRootPath
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.workspaceTitle = workspaceTitle
        self.createdHead = createdHead
        self.generatedArtifactRelativePath = generatedArtifactRelativePath
        self.generatedArtifactContents = generatedArtifactContents
        self.worktreeDeviceID = worktreeDeviceID
        self.worktreeFileID = worktreeFileID
        self.setupCommand = setupCommand
    }
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
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    func rollbackUnclaimedWorktree() async throws {
        do {
            try await Task.detached(priority: .utility) {
                let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
                let projectRootURL = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
                guard let expectedDeviceID = worktreeDeviceID,
                      let expectedFileID = worktreeFileID,
                      try filesystemIdentityMatches(
                          worktreeURL,
                          deviceID: expectedDeviceID,
                          fileID: expectedFileID
                      ) else {
                    throw rollbackRefused(
                        "Worktree path no longer identifies the created checkout."
                    )
                }
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
                let topLevel = try decodedRollbackGitOutput(
                    topLevelData,
                    operation: "resolve worktree root"
                )
                let reportedTopLevelURL = URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL
                guard try refersToSameFileSystemItem(worktreeURL, reportedTopLevelURL) else {
                    throw rollbackRefused("Worktree path no longer identifies the created checkout.")
                }

                let branchRef = "refs/heads/\(branchName)"
                let checkedOutBranchData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                    "git",
                    ["-C", worktreeURL.path, "symbolic-ref", "--quiet", "HEAD"],
                    failureDescription: "Could not remove the unclaimed worktree."
                )
                let checkedOutBranch = try decodedRollbackGitOutput(
                    checkedOutBranchData,
                    operation: "resolve checked-out branch"
                )
                guard checkedOutBranch == branchRef else {
                    throw rollbackRefused("Worktree branch changed after creation.")
                }

                let worktreeHeadData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                    "git",
                    ["-C", worktreeURL.path, "rev-parse", "--verify", "HEAD"],
                    failureDescription: "Could not remove the unclaimed worktree."
                )
                let worktreeHead = try decodedRollbackGitOutput(
                    worktreeHeadData,
                    operation: "resolve worktree HEAD"
                )
                let branchHeadData = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                    "git",
                    ["-C", projectRootURL.path, "rev-parse", "--verify", branchRef],
                    failureDescription: "Could not remove the unclaimed worktree."
                )
                let branchHead = try decodedRollbackGitOutput(
                    branchHeadData,
                    operation: "resolve branch HEAD"
                )
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
                let untrackedPaths = try decodedRollbackGitPaths(
                    untrackedData,
                    operation: "list untracked paths"
                )
                let ignoredPaths = try decodedRollbackGitPaths(
                    ignoredData,
                    operation: "list ignored paths"
                )
                guard (untrackedPaths + ignoredPaths).sorted() == [generatedArtifactRelativePath] else {
                    throw rollbackRefused("Untracked or ignored worktree content changed after creation.")
                }

                try validateGeneratedArtifact(at: artifactURL)
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
                let worktreeLockPath = try decodedRollbackGitOutput(
                    worktreeLockPathData,
                    operation: "resolve worktree lock path"
                )
                guard !worktreeLockPath.isEmpty else {
                    throw rollbackRefused("Could not resolve the worktree lock path.")
                }
                let worktreeLockURL = worktreeLockPath.hasPrefix("/")
                    ? URL(fileURLWithPath: worktreeLockPath).standardizedFileURL
                    : worktreeURL.appendingPathComponent(worktreeLockPath).standardizedFileURL
                guard !FileManager.default.fileExists(atPath: worktreeLockURL.path) else {
                    throw rollbackRefused("Worktree is locked.")
                }

                guard try filesystemIdentityMatches(
                    worktreeURL,
                    deviceID: expectedDeviceID,
                    fileID: expectedFileID
                ) else {
                    throw rollbackRefused(
                        "Worktree path changed before rollback cleanup."
                    )
                }

                let artifactBackupURL = worktreeURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".cmux-rollback-\(UUID().uuidString)", isDirectory: false)
                try FileManager.default.moveItem(at: artifactURL, to: artifactBackupURL)
                do {
                    // Revalidate the exact object moved out of the worktree before
                    // any await or destructive cleanup. The artifact may have been
                    // replaced while the lock-path subprocess was suspended.
                    try validateGeneratedArtifact(at: artifactBackupURL)
                } catch {
                    do {
                        // Preserve the moved contents even when they no longer match
                        // the generated template: they may be user edits that raced
                        // with rollback validation.
                        try restoreMovedGeneratedArtifact(from: artifactBackupURL, to: artifactURL)
                    } catch let restoreError {
                        throw rollbackRefused(
                            "Generated artifact changed during rollback and could not be restored; backup retained at "
                                + artifactBackupURL.path + ". " + restoreError.localizedDescription
                        )
                    }
                    throw rollbackRefused("Generated artifact changed during rollback; checkout was preserved.")
                }

                do {
                    guard try filesystemIdentityMatches(
                        worktreeURL,
                        deviceID: expectedDeviceID,
                        fileID: expectedFileID
                    ) else {
                        throw rollbackRefused(
                            "Worktree path changed before destructive cleanup."
                        )
                    }
                    try await CmuxExtensionWorktreePrototype.run(
                        "rmdir",
                        [artifactDirectory.path],
                        failureDescription: "Could not remove the unclaimed worktree."
                    )
                    guard try filesystemIdentityMatches(
                        worktreeURL,
                        deviceID: expectedDeviceID,
                        fileID: expectedFileID
                    ) else {
                        throw rollbackRefused(
                            "Worktree path changed before branch cleanup."
                        )
                    }
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

                // Remove the backup only after cleanup confirms that the moved
                // inode still contains the generated bytes. If a writer changed
                // it during the awaited cleanup commands, retain that one
                // recovery record instead of discarding the user's edit.
                do {
                    try validateGeneratedArtifact(at: artifactBackupURL)
                    try FileManager.default.removeItem(at: artifactBackupURL)
                } catch {
                    // The backup is intentionally retained as the recovery record
                    // for this failed/contended rollback. The generated artifact is
                    // small and the record is already under the ignored worktree
                    // root, so no additional copy or path race is introduced.
                    throw rollbackRefused(
                        "Generated artifact changed during cleanup; recovery backup retained."
                    )
                }
            }.value
        } catch let error as NSError where error.domain == "CmuxExtensionWorktreePrototype" {
            throw error
        } catch {
            throw rollbackRefused(
                "Rollback failed: \(String(describing: error))"
            )
        }
    }

    private func decodedRollbackGitOutput(
        _ data: Data,
        operation: String
    ) throws -> String {
        guard let output = String(bytes: data, encoding: .utf8) else {
            throw rollbackRefused("Git returned invalid UTF-8 while attempting to \(operation).")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodedRollbackGitPaths(
        _ data: Data,
        operation: String
    ) throws -> [String] {
        guard let output = String(bytes: data, encoding: .utf8) else {
            throw rollbackRefused("Git returned invalid UTF-8 while attempting to \(operation).")
        }
        return output.split(separator: "\0").map(String.init)
    }

    private func refersToSameFileSystemItem(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsIdentity = try filesystemIdentity(at: lhs)
        let rhsIdentity = try filesystemIdentity(at: rhs)
        return lhsIdentity == rhsIdentity
    }

    private func filesystemIdentityMatches(
        _ url: URL,
        deviceID: UInt64,
        fileID: UInt64
    ) throws -> Bool {
        try filesystemIdentity(at: url) == (deviceID: deviceID, fileID: fileID)
    }

    private func filesystemIdentity(at url: URL) throws -> (deviceID: UInt64, fileID: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw rollbackRefused("Could not resolve worktree filesystem identity.")
        }
        return (deviceID, fileID)
    }

    private func validateGeneratedArtifact(at artifactURL: URL) throws {
        let artifactValues = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard artifactValues.isRegularFile == true,
              artifactValues.isSymbolicLink != true,
              try Data(contentsOf: artifactURL) == generatedArtifactContents else {
            throw rollbackRefused("Generated artifact changed after creation.")
        }
    }

    private func restoreGeneratedArtifact(from backupURL: URL, to artifactURL: URL) throws {
        try validateGeneratedArtifact(at: backupURL)
        try restoreMovedGeneratedArtifact(from: backupURL, to: artifactURL)
    }

    private func restoreMovedGeneratedArtifact(from backupURL: URL, to artifactURL: URL) throws {
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
        guard !FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw rollbackRefused("Generated artifact destination changed before it could be restored.")
        }
        try FileManager.default.moveItem(at: backupURL, to: artifactURL)
    }

    private func rollbackRefused(_ details: String) -> NSError {
        CmuxExtensionWorktreePrototype.logPrivateFailure(details)
        return NSError(
            domain: "CmuxExtensionWorktreePrototype",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not remove the unclaimed worktree."]
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
    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "ExtensionWorktree"
    )

    fileprivate static func logPrivateFailure(_ details: String) {
        logger.error("Extension worktree operation failed: \(details, privacy: .private)")
    }

    private static func logPrivateDiagnostic(_ details: String) {
        logger.debug("Extension worktree command diagnostic: \(details, privacy: .private)")
    }

    static func createWorktree(projectRootPath: String) async throws -> CmuxExtensionWorktreeCreationResult {
        do {
            return try await Task.detached(priority: .userInitiated) {
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
                let worktreeIdentity = Self.filesystemIdentity(at: worktree)
                var createdHead: String?
                do {
                    let createdHeadData = try await runCapturingOutput(
                        "git",
                        ["-C", worktree.path, "rev-parse", "--verify", "HEAD"]
                    )
                    guard let decodedHead = String(bytes: createdHeadData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !decodedHead.isEmpty else {
                        logPrivateFailure("Git returned an empty or non-UTF-8 worktree HEAD.")
                        throw NSError(
                            domain: "CmuxExtensionWorktreePrototype",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Could not create worktree."]
                        )
                    }
                    createdHead = decodedHead
                    let generatedArtifact = try writeSampleDevServerFiles(
                        in: worktree,
                        projectName: projectRoot.lastPathComponent
                    )
                    guard let (worktreeDeviceID, worktreeFileID) = worktreeIdentity else {
                        throw NSError(
                            domain: "CmuxExtensionWorktreePrototype",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Could not create worktree."]
                        )
                    }

                    let port = 4_100 + abs(branchName.hashValue % 800)
                    let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
                    return CmuxExtensionWorktreeCreationResult(
                        projectRootPath: projectRoot.path,
                        worktreePath: worktree.path,
                        branchName: branchName,
                        workspaceTitle: branchName,
                        createdHead: decodedHead,
                        generatedArtifactRelativePath: generatedArtifact.relativePath,
                        generatedArtifactContents: generatedArtifact.contents,
                        worktreeDeviceID: worktreeDeviceID,
                        worktreeFileID: worktreeFileID,
                        setupCommand: "cd \(samplePath) && python3 -m http.server \(port)"
                    )
                } catch {
                    await bestEffortCleanupFailedWorktree(
                        projectRoot: projectRoot,
                        worktree: worktree,
                        branchName: branchName,
                        expectedHead: createdHead,
                        expectedIdentity: worktreeIdentity
                    )
                    throw error
                }
            }.value
        } catch let error as NSError where error.domain == "CmuxExtensionWorktreePrototype" {
            throw error
        } catch {
            logPrivateFailure("Worktree creation failed: \(String(describing: error))")
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not create worktree."]
            )
        }
    }

    /// Removes a checkout created by this operation when a later setup step
    /// fails before a rollback result can be handed to the caller. Every
    /// identity check is best-effort and failure leaves the checkout intact.
    private static func bestEffortCleanupFailedWorktree(
        projectRoot: URL,
        worktree: URL,
        branchName: String,
        expectedHead: String?,
        expectedIdentity: (deviceID: UInt64, fileID: UInt64)?
    ) async {
        guard let expectedIdentity,
              let currentIdentity = filesystemIdentity(at: worktree),
              currentIdentity.deviceID == expectedIdentity.deviceID,
              currentIdentity.fileID == expectedIdentity.fileID else {
            logPrivateDiagnostic("Skipped failed worktree cleanup after identity changed.")
            return
        }
        let branchRef = "refs/heads/\(branchName)"
        do {
            let branchData = try await runCapturingOutput(
                "git",
                ["-C", worktree.path, "symbolic-ref", "--quiet", "HEAD"]
            )
            guard String(data: branchData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == branchRef else {
                return
            }
            let headData = try await runCapturingOutput(
                "git",
                ["-C", worktree.path, "rev-parse", "--verify", "HEAD"]
            )
            guard let currentHead = String(data: headData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !currentHead.isEmpty,
                  expectedHead == nil || expectedHead == currentHead else {
                return
            }
            try await run(
                "git",
                ["-C", projectRoot.path, "worktree", "remove", "--force", worktree.path],
                failureDescription: "Could not create worktree."
            )
            try await run(
                "git",
                ["-C", projectRoot.path, "update-ref", "-d", branchRef, currentHead],
                failureDescription: "Could not create worktree."
            )
        } catch {
            logPrivateDiagnostic(
                "Failed-worktree cleanup was skipped: \(String(describing: error))"
            )
        }
    }

    private static func filesystemIdentity(
        at url: URL
    ) -> (deviceID: UInt64, fileID: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let deviceID = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return (deviceID, fileID)
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

    static func runCapturingOutput(
        _ executable: String,
        _ arguments: [String],
        failureDescription: String = "Could not create worktree."
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        let termination = CmuxExtensionProcessTermination()
        process.terminationHandler = { process in
            termination.complete(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            logPrivateFailure(
                "Could not launch \(executable): \(String(describing: error))"
            )
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: failureDescription]
            )
        }
        let outputCollector = CmuxExtensionPipeOutputCollector(
            fileHandle: standardOutputPipe.fileHandleForReading
        )
        let errorCollector = CmuxExtensionPipeOutputCollector(
            fileHandle: standardErrorPipe.fileHandleForReading
        )
        let terminationStatus = await termination.wait()
        let outputData = await outputCollector.finish()
        let errorData = await errorCollector.finish()
        guard terminationStatus == 0 else {
            let outputDetails = String(data: outputData, encoding: .utf8)
                ?? "<non-UTF-8 stdout>"
            let errorDetails = String(data: errorData, encoding: .utf8)
                ?? "<non-UTF-8 stderr>"
            logPrivateFailure(
                "\(executable) exited with status \(terminationStatus); "
                    + "stdout=\(outputDetails); stderr=\(errorDetails)"
            )
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: failureDescription]
            )
        }
        if !errorData.isEmpty {
            let errorDetails = String(data: errorData, encoding: .utf8)
                ?? "<non-UTF-8 stderr>"
            logPrivateDiagnostic(
                "\(executable) succeeded with stderr=\(errorDetails)"
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
