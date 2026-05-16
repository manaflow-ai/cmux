import Foundation

enum EphemeralWorktreeCleanupPolicy: String, Codable, Sendable, Equatable {
    case snapshot
    case block

    static let defaultPolicy: Self = .snapshot

    init?(userValue: String?) {
        guard let userValue else {
            self = .defaultPolicy
            return
        }
        switch userValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "snapshot", "snap":
            self = .snapshot
        case "block", "confirm":
            self = .block
        default:
            return nil
        }
    }
}

struct EphemeralWorktreeRecord: Codable, Sendable, Equatable {
    var sessionId: String
    var sourceRepositoryPath: String
    var worktreePath: String
    var branchName: String
    var cleanupPolicy: EphemeralWorktreeCleanupPolicy
    var createdAt: Date
}

struct EphemeralWorktreeCleanupResult: Sendable, Equatable {
    var dirtyBeforeCleanup: Bool
    var abandonedBranchName: String?
}

enum EphemeralWorktreeLifecycleError: LocalizedError {
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
                defaultValue: "Worktree mode requires a git repository."
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

struct EphemeralWorktreeGitClient {
    struct CommandResult: Sendable {
        let exitCode: Int32
        let output: String

        var succeeded: Bool { exitCode == 0 }
    }

    var fileManager: FileManager = .default

    func repositoryRoot(containing directory: String) throws -> String {
        let result = try runGit(["-C", directory, "rev-parse", "--show-toplevel"], allowFailure: true)
        guard result.succeeded else {
            throw EphemeralWorktreeLifecycleError.notGitRepository(directory)
        }
        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw EphemeralWorktreeLifecycleError.notGitRepository(directory)
        }
        return root
    }

    func createWorktree(_ record: EphemeralWorktreeRecord) throws {
        let parentURL = URL(fileURLWithPath: record.worktreePath).deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try runGitChecked([
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
        try runGitChecked(["-C", record.worktreePath, "add", "-A"])
        try runGitChecked([
            "-C", record.worktreePath,
            "-c", "user.name=cmux",
            "-c", "user.email=cmux@localhost",
            "commit",
            "-m", "cmux snapshot abandoned session \(record.sessionId)",
        ])
        try runGitChecked(["-C", record.worktreePath, "branch", branchName, "HEAD"])
        return branchName
    }

    func removeWorktree(_ record: EphemeralWorktreeRecord) throws {
        if fileManager.fileExists(atPath: record.worktreePath) {
            try runGitChecked([
                "-C", record.sourceRepositoryPath,
                "worktree", "remove",
                "--force",
                record.worktreePath,
            ])
        }

        if try branchExists(record.branchName, in: record.sourceRepositoryPath) {
            try runGitChecked(["-C", record.sourceRepositoryPath, "branch", "-D", record.branchName])
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
        return result.output
    }

    func runGit(_ arguments: [String], allowFailure: Bool) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let result = CommandResult(exitCode: process.terminationStatus, output: output)
        if !allowFailure && !result.succeeded {
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

final class EphemeralWorktreeRegistry: @unchecked Sendable {
    static let shared = EphemeralWorktreeRegistry()

    private let storeURL: URL
    private let git: EphemeralWorktreeGitClient
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        storeURL: URL = EphemeralWorktreeRegistry.defaultStoreURL(),
        git: EphemeralWorktreeGitClient = EphemeralWorktreeGitClient(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.git = git
        self.fileManager = fileManager
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
        let repositoryURL = URL(fileURLWithPath: sourceRepositoryPath, isDirectory: true)
        let worktreePath = repositoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("cmux-\(sessionId)", isDirectory: true)
            .path
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

    func register(_ record: EphemeralWorktreeRecord) throws {
        try updateRecords { records in
            records.removeAll { $0.sessionId == record.sessionId }
            records.append(record)
        }
    }

    func records() -> [EphemeralWorktreeRecord] {
        lock.withLocked {
            loadRecordsUnlocked()
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
        Task.detached(priority: .utility) {
            do {
                _ = try self.cleanup(record, userConfirmed: userConfirmed)
            } catch {
                NSLog(
                    "[cmux] Ephemeral worktree cleanup failed for session %@: %@",
                    String(record.sessionId.prefix(8)),
                    error.localizedDescription
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
                Result { try cleanup(record, userConfirmed: true) }
            }
    }

    func reconcileOrphansInBackground(activeSessionIds: Set<String>) {
        Task.detached(priority: .utility) {
            _ = self.reconcileOrphans(activeSessionIds: activeSessionIds)
        }
    }

    private func unregister(sessionId: String) throws {
        try updateRecords { records in
            records.removeAll { $0.sessionId == sessionId }
        }
    }

    private func updateRecords(_ mutation: (inout [EphemeralWorktreeRecord]) -> Void) throws {
        try lock.withLocked {
            var records = loadRecordsUnlocked()
            mutation(&records)
            try saveRecordsUnlocked(records)
        }
    }

    private func loadRecordsUnlocked() -> [EphemeralWorktreeRecord] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([EphemeralWorktreeRecord].self, from: data)) ?? []
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
