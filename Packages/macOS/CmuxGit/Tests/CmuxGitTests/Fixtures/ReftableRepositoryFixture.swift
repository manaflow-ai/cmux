import Foundation

/// A real on-disk repository created with git's reftable ref backend
/// (`git init --ref-format=reftable`), for the metadata reads that cannot be
/// answered from `.git/HEAD` alone.
///
/// Unlike ``GitRepositoryFixture`` this drives a `git` process, because the
/// reftable stack is a binary format written only by git. It uses
/// `/usr/bin/git` — the same binary ``SystemWorkspaceChangesGitRunner`` runs —
/// with system and global config disabled, so the developer's own hooks,
/// `core.hooksPath`, signing, and defaults cannot change the fixture. Removed
/// on `deinit`.
final class ReftableRepositoryFixture {
    /// Whether the git this fixture drives can create reftable repositories.
    /// `--ref-format` landed in git 2.45, so older toolchains (notably the
    /// Xcode git on CI images) cannot host these tests; the suite skips on
    /// `false` instead of failing.
    static let isSupported: Bool = {
        guard let probeRoot = try? makeTemporaryDirectory(prefix: "cmuxgit-reftable-probe") else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        guard (try? run(["init", "--ref-format=reftable", "."], in: probeRoot)) != nil else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: probeRoot.appendingPathComponent(".git/reftable/tables.list").path
        )
    }()

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// The working-tree root of the main checkout.
    let root: URL

    /// Enclosing scratch directory holding the main checkout and any linked
    /// worktrees, so one removal cleans all of them up.
    private let base: URL

    /// Creates a reftable repository with one empty commit, checked out on
    /// `branch`.
    init(branch: String) throws {
        base = try Self.makeTemporaryDirectory(prefix: "cmuxgit-reftable")
        root = base.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run(["init", "--ref-format=reftable", "--initial-branch=main", "."])
        try run(["commit", "--allow-empty", "--message", "init"])
        if branch != "main" {
            try run(["checkout", "-b", branch])
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// Creates and checks out `branch` in the main working tree.
    func checkoutNewBranch(_ branch: String) throws {
        try run(["checkout", "-b", branch])
    }

    /// Detaches `HEAD` onto the commit it currently points at.
    func detachHead() throws {
        try run(["checkout", "--detach"])
    }

    /// Adds an empty commit so the checked-out branch advances.
    func commitEmpty(message: String) throws {
        try run(["commit", "--allow-empty", "--message", message])
    }

    /// Adds a linked worktree (`git worktree add`) on a new `branch` and
    /// returns its working-tree root. Linked worktrees keep their own reftable
    /// stack next to their per-worktree `HEAD` stub.
    func addWorktree(name: String, branch: String) throws -> URL {
        let worktreeRoot = base.appendingPathComponent(name, isDirectory: true)
        try run(["worktree", "add", "-b", branch, worktreeRoot.path])
        return worktreeRoot
    }

    /// The commit `HEAD` resolves to, as 40 lowercase hex characters.
    func headCommit() throws -> String {
        try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        try Self.run(arguments, in: root)
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.arguments = [
            "-c", "user.name=cmux tests",
            "-c", "user.email=tests@cmux.invalid",
            "-c", "commit.gpgsign=false",
        ] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Drop every inherited GIT_* variable first. GIT_DIR would point the
        // fixture at another repository entirely, and GIT_TEMPLATE_DIR can
        // install hooks that run during `commit`.
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        // Neutralize the developer's own git configuration and hooks.
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        // Both streams go to files rather than pipes: a pipe read sequence
        // deadlocks whenever the stream being read second fills its buffer
        // first, and a fixture has no reason to risk it.
        let captureDirectory = try makeTemporaryDirectory(prefix: "cmuxgit-reftable-capture")
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        try process.run()
        process.waitUntilExit()
        try? outputHandle.close()
        try? errorHandle.close()

        let outputData = (try? Data(contentsOf: outputURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
            throw Failure(
                arguments: arguments,
                exitCode: process.terminationStatus,
                standardError: String(decoding: errorData, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    struct Failure: Error, CustomStringConvertible {
        let arguments: [String]
        let exitCode: Int32
        let standardError: String

        var description: String {
            "git \(arguments.joined(separator: " ")) failed with \(exitCode): \(standardError)"
        }
    }
}
