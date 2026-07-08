import CmuxGit
import Foundation

// MARK: - Mobile workspace diff review

extension TerminalController {
    nonisolated static let mobileWorkspaceDiffByteCap = 2 * 1024 * 1024
    /// Process-level bound on diff bytes read from git, slightly above the
    /// response cap so `utf8BoundaryCapped` still sees more than
    /// `mobileWorkspaceDiffByteCap` bytes and reports truncation. Keeps a huge
    /// diff from accumulating unbounded memory before response capping.
    nonisolated static let mobileWorkspaceDiffReadCap = mobileWorkspaceDiffByteCap + 4096
    /// Upper bound on changed-file rows returned to the phone; larger change
    /// sets are cut off and reported as truncated so the response stays a
    /// mobile-sized payload.
    nonisolated static let mobileWorkspaceDiffMaxFiles = 4000

    func v2MobileWorkspaceDiffStatus(params: [String: Any]) async -> V2CallResult {
        switch mobileWorkspaceDiffSnapshot(params: params) {
        case .failure(let error):
            return error
        case .success(let snapshot):
            let result = await Self.mobileWorkspaceDiffStatusResult(directory: snapshot.directory)
            return Self.v2MobileWorkspaceDiffResult(result)
        }
    }

    func v2MobileWorkspaceDiffFile(params: [String: Any]) async -> V2CallResult {
        guard let rawPath = params["path"] as? String,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid path", data: nil)
        }
        switch mobileWorkspaceDiffSnapshot(params: params) {
        case .failure(let error):
            return error
        case .success(let snapshot):
            let result = await Self.mobileWorkspaceDiffFileResult(directory: snapshot.directory, path: rawPath)
            return Self.v2MobileWorkspaceDiffResult(result)
        }
    }

    /// Isolation invariant: this is a MAIN-ACTOR-isolated method (the
    /// enclosing `TerminalController` is `@MainActor` and nothing here is
    /// `nonisolated`), so every workspace/tab-manager read below runs on the
    /// main actor. The socket-worker lane reaches it only through
    /// `await v2MobileWorkspaceDiffStatus/File`, whose actor hop covers the
    /// whole snapshot; the internal `v2MainSync` hops in
    /// `v2ResolveTabManager` collapse inline on the main thread. Only the
    /// Sendable `directory` string crosses into the detached git work.
    private func mobileWorkspaceDiffSnapshot(params: [String: Any]) -> MobileWorkspaceDiffSnapshotResult {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceID == nil {
            return .failure(.err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .failure(.err(code: "unavailable", message: "Workspace context is unavailable", data: nil))
        }
        guard !workspace.isRemoteWorkspace else {
            return .failure(.err(code: "unavailable", message: "diff unavailable for remote workspaces", data: nil))
        }
        guard let directory = workspace.presentedCurrentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return .failure(.err(code: "unavailable", message: "Workspace directory is unavailable", data: nil))
        }
        return .success(MobileWorkspaceDiffSnapshot(directory: directory))
    }

    private nonisolated static func mobileWorkspaceDiffStatusResult(directory: String) async -> MobileWorkspaceDiffStatusResult {
        await detachedCancellable {
            mobileWorkspaceDiffStatusResultSync(directory: directory)
        }
    }

    private nonisolated static func mobileWorkspaceDiffFileResult(directory: String, path: String) async -> MobileWorkspaceDiffFileResult {
        await detachedCancellable {
            mobileWorkspaceDiffFileResultSync(directory: directory, path: path)
        }
    }

    /// Runs blocking git work off the main actor while keeping it tied to the
    /// caller's cancellation: `Task.detached` alone severs it, so an RPC
    /// timeout (`v2AsyncResultCall`'s `task.cancel()`) would leave the whole
    /// multi-subprocess pipeline running to completion. The handler forwards
    /// cancellation into the detached task, and `GitDiffService` bails between
    /// subprocess invocations when its task is cancelled, so a timed-out
    /// request stops at the next process boundary instead of running the full
    /// sequence (each process is separately deadline-bounded by the service's
    /// watchdog).
    private nonisolated static func detachedCancellable<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result
    ) async -> Result {
        let task = Task.detached(priority: .utility) {
            work()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func mobileWorkspaceDiffStatusResultSync(directory: String) -> MobileWorkspaceDiffStatusResult {
        let service = GitDiffService()
        guard let repoRoot = service.repositoryRoot(for: directory) else {
            return .repositoryNotFound
        }
        let changed = service.changedFiles(repoRoot: repoRoot, maxOutputBytes: mobileWorkspaceDiffByteCap)
        let files = Array(changed.files.prefix(mobileWorkspaceDiffMaxFiles))
        return .ok(
            repoRoot: repoRoot,
            files: files,
            truncated: changed.truncated || files.count < changed.files.count
        )
    }

    private nonisolated static func mobileWorkspaceDiffFileResultSync(directory: String, path: String) -> MobileWorkspaceDiffFileResult {
        let service = GitDiffService()
        guard let repoRoot = service.repositoryRoot(for: directory) else {
            return .repositoryNotFound
        }
        guard let diff = service.fileDiff(repoRoot: repoRoot, path: path, maxOutputBytes: mobileWorkspaceDiffReadCap) else {
            return .fileNotFound(path: path)
        }
        let capped = utf8BoundaryCapped(diff.unifiedDiff, byteLimit: mobileWorkspaceDiffByteCap)
        return .ok(path: diff.path, unifiedDiff: capped.text, truncated: capped.truncated)
    }

    private nonisolated static func utf8BoundaryCapped(_ text: String, byteLimit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > byteLimit else {
            return (text, false)
        }
        var endIndex = text.startIndex
        var byteCount = 0
        while endIndex < text.endIndex {
            let nextIndex = text.index(after: endIndex)
            let nextByteCount = text[endIndex].utf8.count
            guard byteCount + nextByteCount <= byteLimit else { break }
            byteCount += nextByteCount
            endIndex = nextIndex
        }
        return (String(text[..<endIndex]), true)
    }

    private nonisolated static func v2MobileWorkspaceDiffResult(_ result: MobileWorkspaceDiffStatusResult) -> V2CallResult {
        switch result {
        case .repositoryNotFound:
            return .err(code: "not_found", message: "Git repository not found", data: nil)
        case .ok(let repoRoot, let summaries, let truncated):
            let files = summaries.map { summary in
                [
                    "path": summary.path,
                    "old_path": jsonOrNull(summary.oldPath),
                    "status": summary.status.rawValue,
                    "additions": jsonOrNull(summary.additions),
                    "deletions": jsonOrNull(summary.deletions),
                ] as [String: Any]
            }
            return .ok([
                "repo_root": repoRoot,
                "files": files,
                "truncated": truncated,
            ])
        }
    }

    private nonisolated static func v2MobileWorkspaceDiffResult(_ result: MobileWorkspaceDiffFileResult) -> V2CallResult {
        switch result {
        case .repositoryNotFound:
            return .err(code: "not_found", message: "Git repository not found", data: nil)
        case .fileNotFound(let path):
            return .err(code: "not_found", message: "File diff not found", data: ["path": path])
        case .ok(let path, let unifiedDiff, let truncated):
            return .ok([
                "path": path,
                "unified_diff": unifiedDiff,
                "truncated": truncated,
            ])
        }
    }

    private nonisolated static func jsonOrNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

private struct MobileWorkspaceDiffSnapshot {
    let directory: String
}

private enum MobileWorkspaceDiffSnapshotResult {
    case success(MobileWorkspaceDiffSnapshot)
    case failure(TerminalController.V2CallResult)
}

private enum MobileWorkspaceDiffStatusResult: Sendable {
    case repositoryNotFound
    case ok(repoRoot: String, files: [GitDiffSummary], truncated: Bool)
}

private enum MobileWorkspaceDiffFileResult: Sendable {
    case repositoryNotFound
    case fileNotFound(path: String)
    case ok(path: String, unifiedDiff: String, truncated: Bool)
}
