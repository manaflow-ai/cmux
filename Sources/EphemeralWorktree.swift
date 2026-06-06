import Darwin
import Foundation
import os

nonisolated enum EphemeralWorktreeCleanupPolicy: String, Codable, Sendable, Equatable {
    case snapshot
    case block

    static let defaultPolicy: Self = .snapshot

    init?(userValue: String?) {
        guard let userValue else {
            self = .defaultPolicy
            return
        }
        let normalized = userValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "snapshot", "snap":
            self = .snapshot
        case "block", "confirm":
            self = .block
        default:
            return nil
        }
    }
}

nonisolated struct EphemeralWorktreeRecord: Codable, Sendable, Equatable {
    var sessionId: String
    var sourceRepositoryPath: String
    var worktreePath: String
    var branchName: String
    var cleanupPolicy: EphemeralWorktreeCleanupPolicy
    var createdAt: Date

    func matchingWorktreeDirectory(forSourceDirectory sourceDirectory: String?) -> String {
        guard let sourcePath = Self.standardizedNonEmptyPath(sourceDirectory),
              let repositoryPath = Self.standardizedNonEmptyPath(sourceRepositoryPath),
              let worktreeRoot = Self.standardizedNonEmptyPath(worktreePath),
              Self.isPath(sourcePath, inside: repositoryPath) else {
            return worktreePath
        }

        var relativePath = String(sourcePath.dropFirst(repositoryPath.count))
        while relativePath.first == "/" {
            relativePath.removeFirst()
        }
        guard !relativePath.isEmpty else {
            return worktreePath
        }
        return URL(fileURLWithPath: worktreeRoot, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
            .path
    }

    func matchingSourceDirectory(forWorktreeDirectory worktreeDirectory: String?) -> String? {
        guard let worktreeDirectory = Self.standardizedNonEmptyPath(worktreeDirectory),
              let repositoryPath = Self.standardizedNonEmptyPath(sourceRepositoryPath),
              let worktreeRoot = Self.standardizedNonEmptyPath(worktreePath),
              Self.isPath(worktreeDirectory, inside: worktreeRoot) else {
            return nil
        }

        var relativePath = String(worktreeDirectory.dropFirst(worktreeRoot.count))
        while relativePath.first == "/" {
            relativePath.removeFirst()
        }
        guard !relativePath.isEmpty else {
            return repositoryPath
        }
        return URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
            .path
    }

    private static func standardizedNonEmptyPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).standardizingPath
    }

    private static func isPath(_ candidate: String, inside root: String) -> Bool {
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

nonisolated struct EphemeralWorktreeCleanupResult: Sendable, Equatable {
    var dirtyBeforeCleanup: Bool
    var abandonedBranchName: String?
}

nonisolated enum EphemeralWorktreeLifecycleError: LocalizedError {
    case invalidCleanupPolicy(String)
    case notGitRepository(String)
    case dirtyWorktreeRequiresConfirmation(String)
    case commandFailed(command: String, exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .invalidCleanupPolicy(let value):
            return String.localizedStringWithFormat(
                String(
                    localized: "error.ephemeralWorktree.invalidCleanupPolicy",
                    defaultValue: "Unsupported worktree cleanup policy: %@"
                ),
                value
            )
        case .notGitRepository:
            return String(
                localized: "error.ephemeralWorktree.notGitRepository",
                defaultValue: "worktree mode requires a git repository."
            )
        case .dirtyWorktreeRequiresConfirmation:
            return String(
                localized: "error.ephemeralWorktree.dirtyRequiresConfirmation",
                defaultValue: "This worktree cleanup policy requires confirmation before removal."
            )
        case .commandFailed:
            return String(
                localized: "error.ephemeralWorktree.commandFailed",
                defaultValue: "A git operation failed while managing the ephemeral worktree."
            )
        }
    }

    var debugDescription: String {
        switch self {
        case .invalidCleanupPolicy(let value):
            return "invalid cleanup policy: \(value)"
        case .notGitRepository(let path):
            return "not a git repository: \(path)"
        case .dirtyWorktreeRequiresConfirmation(let path):
            return "dirty worktree requires confirmation: \(path)"
        case .commandFailed(let command, let exitCode, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git command failed (\(command), exit \(exitCode)): \(detail.isEmpty ? "no output" : detail)"
        }
    }
}

nonisolated struct EphemeralWorktreeGitClient {
    private static let gitCommandTimeoutSeconds = 120
    private static let gitCommandTerminationGraceSeconds = 5

    struct CommandResult: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String

        var succeeded: Bool { exitCode == 0 }
        var output: String {
            [standardOutput, standardError]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    var fileManager: FileManager = .default

    func repositoryRoot(containing directory: String) throws -> String {
        let result = try runGit(["-C", directory, "rev-parse", "--show-toplevel"], allowFailure: true)
        guard result.succeeded else {
            throw EphemeralWorktreeLifecycleError.notGitRepository(directory)
        }
        let root = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw EphemeralWorktreeLifecycleError.notGitRepository(directory)
        }
        return root
    }

    func createWorktree(_ record: EphemeralWorktreeRecord) throws {
        let parentURL = URL(fileURLWithPath: record.worktreePath).deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        _ = try runGitChecked([
            "-C", record.sourceRepositoryPath,
            "worktree", "add",
            "-b", record.branchName,
            record.worktreePath,
            "HEAD",
        ])
    }

    func hasUncommittedChanges(_ record: EphemeralWorktreeRecord) throws -> Bool {
        guard fileManager.fileExists(atPath: record.worktreePath) else { return false }
        let result = try runGitChecked([
            "-C", record.worktreePath,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        ])
        return !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func snapshotUncommittedChanges(_ record: EphemeralWorktreeRecord) throws -> String {
        let branchName = abandonedBranchName(for: record)
        _ = try runGitChecked(["-C", record.worktreePath, "add", "-A"])
        let tree = try runGitChecked(["-C", record.worktreePath, "write-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try runGitChecked(["-C", record.worktreePath, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try runGitChecked([
            "-C", record.worktreePath,
            "-c", "user.name=cmux",
            "-c", "user.email=cmux@localhost",
            "commit-tree",
            tree,
            "-p", parent,
            "-m", "cmux snapshot abandoned session \(record.sessionId)",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runGitChecked([
            "-C", record.sourceRepositoryPath,
            "update-ref",
            "refs/heads/\(branchName)",
            commit,
        ])
        return branchName
    }

    func removeWorktree(_ record: EphemeralWorktreeRecord) throws {
        if fileManager.fileExists(atPath: record.worktreePath) {
            _ = try runGitChecked([
                "-C", record.sourceRepositoryPath,
                "worktree", "remove",
                "--force",
                record.worktreePath,
            ])
        }

        if try branchExists(record.branchName, in: record.sourceRepositoryPath) {
            _ = try runGitChecked(["-C", record.sourceRepositoryPath, "branch", "-D", record.branchName])
        }
    }

    func branchExists(_ branchName: String, in repositoryPath: String) throws -> Bool {
        let result = try runGit([
            "-C", repositoryPath,
            "show-ref",
            "--verify",
            "--quiet",
            "refs/heads/\(branchName)",
        ], allowFailure: true)
        return result.succeeded
    }

    func runGitChecked(_ arguments: [String]) throws -> String {
        let result = try runGit(arguments, allowFailure: false)
        return result.standardOutput
    }

    func runGit(_ arguments: [String], allowFailure: Bool) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-worktree-git-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt", isDirectory: false)
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt", isDirectory: false)
        _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? fileManager.removeItem(at: outputDirectory) }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        let timedOut = finished.wait(timeout: .now() + .seconds(Self.gitCommandTimeoutSeconds)) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(Self.gitCommandTerminationGraceSeconds)) == .timedOut,
               process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(1))
            }
        }
        stdoutHandle.synchronizeFile()
        stderrHandle.synchronizeFile()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let timedOutDetail = timedOut
            ? "\nGit command timed out after \(Self.gitCommandTimeoutSeconds) seconds."
            : ""
        let result = CommandResult(
            exitCode: timedOut ? Int32(-SIGTERM) : process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: stderr + timedOutDetail
        )
        if timedOut || (!allowFailure && !result.succeeded) {
            throw EphemeralWorktreeLifecycleError.commandFailed(
                command: (["git"] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                output: result.output
            )
        }
        return result
    }

    private func abandonedBranchName(for record: EphemeralWorktreeRecord) -> String {
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let shortSessionId = record.sessionId.prefix(8)
        return "cmux/abandoned/\(timestamp)-\(shortSessionId)"
    }
}

// Sendable safety: registry persistence is synchronous and all JSON store mutations are serialized by `lock`.
// Async/background entry points run blocking git subprocesses on dedicated GCD queues, not Swift's cooperative executor.
final class EphemeralWorktreeRegistry: @unchecked Sendable {
    static let shared = EphemeralWorktreeRegistry()
    private nonisolated static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "ephemeral-worktree"
    )

    private let storeURL: URL
    private let git: EphemeralWorktreeGitClient
    private let fileManager: FileManager
    // User-initiated creation must not wait behind startup orphan reconciliation.
    private let gitCreationQueue: DispatchQueue
    private let gitMaintenanceQueue: DispatchQueue
    private let lock = NSLock()

    init(
        storeURL: URL = EphemeralWorktreeRegistry.defaultStoreURL(),
        git: EphemeralWorktreeGitClient = EphemeralWorktreeGitClient(),
        fileManager: FileManager = .default,
        gitMaintenanceQueue: DispatchQueue = DispatchQueue(
            label: "com.cmux.ephemeral-worktree.git.maintenance",
            qos: .utility
        ),
        gitCreationQueue: DispatchQueue = DispatchQueue(
            label: "com.cmux.ephemeral-worktree.git.create",
            qos: .userInitiated
        )
    ) {
        self.storeURL = storeURL
        self.git = git
        self.fileManager = fileManager
        self.gitCreationQueue = gitCreationQueue
        self.gitMaintenanceQueue = gitMaintenanceQueue
    }

    static func defaultStoreURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleSegment = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = bundleSegment?.isEmpty == false ? bundleSegment! : "cmux"
        return appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("ephemeral-worktrees.json", isDirectory: false)
    }

    func create(
        sourceDirectory: String,
        cleanupPolicy: EphemeralWorktreeCleanupPolicy = .defaultPolicy
    ) throws -> EphemeralWorktreeRecord {
        let sourceRepositoryPath = try git.repositoryRoot(containing: sourceDirectory)
        let sessionId = UUID().uuidString.lowercased()
        let branchName = "cmux/session-\(sessionId)"
        let worktreePath = Self.worktreePath(
            sourceRepositoryPath: sourceRepositoryPath,
            sessionId: sessionId,
            storeURL: storeURL
        )
        let record = EphemeralWorktreeRecord(
            sessionId: sessionId,
            sourceRepositoryPath: sourceRepositoryPath,
            worktreePath: worktreePath,
            branchName: branchName,
            cleanupPolicy: cleanupPolicy,
            createdAt: .now
        )
        try git.createWorktree(record)
        do {
            try register(record)
        } catch {
            try? git.removeWorktree(record)
            throw error
        }
        return record
    }

    private static func worktreePath(
        sourceRepositoryPath: String,
        sessionId: String,
        storeURL: URL
    ) -> String {
        let namespace = "\(repositorySlug(sourceRepositoryPath))-\(stablePathHash(sourceRepositoryPath))"
        return storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("cmux-\(sessionId)", isDirectory: true)
            .path
    }

    private static func repositorySlug(_ sourceRepositoryPath: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: sourceRepositoryPath, isDirectory: true)
            .lastPathComponent
        let source = lastPathComponent.isEmpty ? "repository" : lastPathComponent
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitized = source.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(sanitized)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return slug.isEmpty ? "repository" : String(slug.prefix(64))
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func createAsync(
        sourceDirectory: String,
        cleanupPolicy: EphemeralWorktreeCleanupPolicy = .defaultPolicy
    ) async throws -> EphemeralWorktreeRecord {
        try await withCheckedThrowingContinuation { continuation in
            gitCreationQueue.async {
                let result: Result<EphemeralWorktreeRecord, Error> = Result {
                    try self.create(
                        sourceDirectory: sourceDirectory,
                        cleanupPolicy: cleanupPolicy
                    )
                }
                continuation.resume(with: result)
            }
        }
    }

    func register(_ record: EphemeralWorktreeRecord) throws {
        try updateRecords { records in
            records.removeAll { $0.sessionId == record.sessionId }
            records.append(record)
        }
    }

    func registerInBackground(_ record: EphemeralWorktreeRecord, reason: String) {
        gitMaintenanceQueue.async {
            do {
                try self.register(record)
            } catch {
                Self.logger.error(
                    "Failed to register \(reason, privacy: .public) ephemeral worktree for session \(String(record.sessionId.prefix(8)), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
#if DEBUG
                let detail = (error as? EphemeralWorktreeLifecycleError)?.debugDescription
                    ?? error.localizedDescription
                cmuxDebugLog(
                    "worktree.\(reason).register.failed session=\(record.sessionId.prefix(8)) " +
                    "error=\(detail)"
                )
#endif
            }
        }
    }

    func records() -> [EphemeralWorktreeRecord] {
        lock.withLocked {
            do {
                return try loadRecordsUnlocked()
            } catch {
                Self.logger.error(
                    "Failed to load ephemeral worktree records: \(error.localizedDescription, privacy: .public)"
                )
                return []
            }
        }
    }

    func hasUncommittedChanges(_ record: EphemeralWorktreeRecord) throws -> Bool {
        try git.hasUncommittedChanges(record)
    }

    @discardableResult
    func cleanup(
        _ record: EphemeralWorktreeRecord,
        userConfirmed: Bool = false
    ) throws -> EphemeralWorktreeCleanupResult {
        let isDirty = try git.hasUncommittedChanges(record)
        if isDirty && record.cleanupPolicy == .block && !userConfirmed {
            throw EphemeralWorktreeLifecycleError.dirtyWorktreeRequiresConfirmation(record.worktreePath)
        }

        let abandonedBranchName = isDirty ? try git.snapshotUncommittedChanges(record) : nil
        try git.removeWorktree(record)
        try unregister(sessionId: record.sessionId)
        return EphemeralWorktreeCleanupResult(
            dirtyBeforeCleanup: isDirty,
            abandonedBranchName: abandonedBranchName
        )
    }

    func cleanupInBackground(_ record: EphemeralWorktreeRecord, userConfirmed: Bool = false) {
        // This is a sync-to-background bridge for git worktree removal after UI teardown.
        // Keeping it off the main actor prevents pane closure from waiting on git I/O.
        gitMaintenanceQueue.async {
            do {
                _ = try self.cleanup(record, userConfirmed: userConfirmed)
            } catch {
                Self.logger.error(
                    "Ephemeral worktree cleanup failed for session \(String(record.sessionId.prefix(8)), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
#if DEBUG
                let detail = (error as? EphemeralWorktreeLifecycleError)?.debugDescription
                    ?? error.localizedDescription
                cmuxDebugLog(
                    "worktree.cleanup.failed session=\(record.sessionId.prefix(8)) " +
                    "error=\(detail)"
                )
#endif
            }
        }
    }

    func reconcileOrphans(activeSessionIds: Set<String>) -> [Result<EphemeralWorktreeCleanupResult, Error>] {
        records()
            .filter { !activeSessionIds.contains($0.sessionId) }
            .map { record in
                Result { try cleanupOrphan(record) }
            }
    }

    func reconcileOrphansInBackground(activeSessionIds: Set<String>) {
        gitMaintenanceQueue.async {
            _ = self.reconcileOrphans(activeSessionIds: activeSessionIds)
        }
    }

    private func unregister(sessionId: String) throws {
        try updateRecords { records in
            records.removeAll { $0.sessionId == sessionId }
        }
    }

    private func cleanupOrphan(_ record: EphemeralWorktreeRecord) throws -> EphemeralWorktreeCleanupResult {
        // Startup reconciliation has no confirmation surface; snapshot dirty
        // `.block` orphans so stale sessions do not accumulate permanently.
        try cleanup(record, userConfirmed: true)
    }

    private func updateRecords(_ mutation: (inout [EphemeralWorktreeRecord]) -> Void) throws {
        try lock.withLocked {
            do {
                var records = try loadRecordsUnlocked()
                mutation(&records)
                try saveRecordsUnlocked(records)
            } catch {
                Self.logger.error(
                    "Aborting ephemeral worktree record update after load/save failure: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
    }

    private func loadRecordsUnlocked() throws -> [EphemeralWorktreeRecord] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        return try JSONDecoder().decode([EphemeralWorktreeRecord].self, from: data)
    }

    private func saveRecordsUnlocked(_ records: [EphemeralWorktreeRecord]) throws {
        let parentURL = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.sorted { $0.sessionId < $1.sessionId })
        try data.write(to: storeURL, options: .atomic)
    }
}

private extension NSLock {
    func withLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
