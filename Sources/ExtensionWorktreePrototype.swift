import CmuxFoundation
import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let worktreePath: String
    let workspaceTitle: String
    /// A convenience command that should run inside the new workspace's
    /// interactive shell. This is *setup*, never the workspace's primary
    /// process.
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
    /// Worktree-created workspaces should stay at a clean shell prompt even
    /// when there is no setup command to type into the terminal.
    let autoWelcomeIfNeeded: Bool
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
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
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
            return CmuxExtensionWorktreeCreationResult(
                worktreePath: worktree.path,
                workspaceTitle: branchName,
                setupCommand: ""
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

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runCapturingOutput(executable, arguments)
    }

    private static func runCapturingOutput(_ executable: String, _ arguments: [String]) async throws -> Data {
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
                    NSLocalizedDescriptionKey: "Could not create worktree.",
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
        }
        return outputData
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
