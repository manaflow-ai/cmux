import CmuxGit
import Foundation

// MARK: - Mobile workspace diff review

extension TerminalController {
    /// The file cap stays below one sixth of the 8 MiB frame limit because JSON
    /// may encode each control byte as a six-byte `\\u00xx` escape.
    nonisolated static let mobileWorkspaceDiffFileByteCap = 1 * 1024 * 1024
    /// Status runs three bounded listings; this keeps their worst-case escaped
    /// aggregate plus envelope metadata below the same 8 MiB frame limit.
    nonisolated static let mobileWorkspaceDiffStatusReadCap = 256 * 1024
    /// Process-level bound on diff bytes read from git, slightly above the
    /// response cap so `utf8BoundaryCapped` still sees more than
    /// `mobileWorkspaceDiffFileByteCap` bytes and reports truncation. Keeps a huge
    /// diff from accumulating unbounded memory before response capping.
    nonisolated static let mobileWorkspaceDiffReadCap = mobileWorkspaceDiffFileByteCap + 4096
    /// Upper bound on changed-file rows returned to the phone; larger change
    /// sets are cut off and reported as truncated so the response stays a
    /// mobile-sized payload.
    nonisolated static let mobileWorkspaceDiffMaxFiles = 4000

    nonisolated func v2MobileWorkspaceDiffWorkerResponse(method: String, id: Any?, params: [String: Any]) -> String? {
        switch method {
        case "mobile.workspace.diff_status":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) { await self.v2MobileWorkspaceDiffStatus(params: params) }
        case "mobile.workspace.diff_file":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) { await self.v2MobileWorkspaceDiffFile(params: params) }
        default:
            return nil
        }
    }

    func v2MobileWorkspaceDiffDataPlaneResult(method: String, params: [String: Any]) async -> V2CallResult? {
        switch method {
        case "mobile.workspace.diff_status":
            return await v2MobileWorkspaceDiffStatus(params: params)
        case "mobile.workspace.diff_file":
            return await v2MobileWorkspaceDiffFile(params: params)
        default:
            return nil
        }
    }

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
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expectedRepoRoot = params["repo_root"] as? String,
              !expectedRepoRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid path", data: nil)
        }
        let oldPath: String?
        if v2HasNonNullParam(params, "old_path") {
            guard let rawOldPath = params["old_path"] as? String,
                  !rawOldPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "Missing or invalid old_path", data: nil)
            }
            oldPath = rawOldPath
        } else {
            oldPath = nil
        }
        switch mobileWorkspaceDiffSnapshot(params: params) {
        case .failure(let error):
            return error
        case .success(let snapshot):
            let result = await Self.mobileWorkspaceDiffFileResult(
                directory: snapshot.directory,
                path: rawPath,
                oldPath: oldPath,
                expectedRepoRoot: expectedRepoRoot
            )
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
        guard !workspace.isRemoteWorkspace, !workspace.isRemoteTmuxMirror else {
            return .failure(.err(code: "unavailable", message: "diff unavailable for remote workspaces", data: nil))
        }
        guard let directory = workspace.presentedCurrentDirectory,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.err(code: "unavailable", message: "Workspace directory is unavailable", data: nil))
        }
        return .success(MobileWorkspaceDiffSnapshot(directory: directory))
    }

    private nonisolated static func mobileWorkspaceDiffStatusResult(directory: String) async -> MobileWorkspaceDiffStatusResult {
        await detachedCancellable {
            mobileWorkspaceDiffStatusResultSync(directory: directory)
        }
    }

    private nonisolated static func mobileWorkspaceDiffFileResult(
        directory: String,
        path: String,
        oldPath: String?,
        expectedRepoRoot: String
    ) async -> MobileWorkspaceDiffFileResult {
        await detachedCancellable {
            mobileWorkspaceDiffFileResultSync(
                directory: directory,
                path: path,
                oldPath: oldPath,
                expectedRepoRoot: expectedRepoRoot
            )
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
        let repoRoot: String
        switch service.repositoryRootResult(for: directory) {
        case .success(let root):
            repoRoot = root
        case .notFound:
            return .repositoryNotFound
        case .failed:
            return .gitFailed
        case .timedOut:
            return .gitTimedOut
        }
        let changed: GitChangedFiles
        switch service.changedFilesResult(
            repoRoot: repoRoot,
            maxOutputBytes: mobileWorkspaceDiffStatusReadCap
        ) {
        case .success(let value):
            changed = value
        case .notFound, .failed:
            return .gitFailed
        case .timedOut:
            return .gitTimedOut
        }
        let files = Array(changed.files.prefix(mobileWorkspaceDiffMaxFiles))
        return .ok(
            repoRoot: repoRoot,
            files: files,
            truncated: changed.truncated || files.count < changed.files.count
        )
    }

    private nonisolated static func mobileWorkspaceDiffFileResultSync(
        directory: String,
        path: String,
        oldPath: String?,
        expectedRepoRoot: String
    ) -> MobileWorkspaceDiffFileResult {
        let service = GitDiffService()
        let repoRoot: String
        switch service.repositoryRootResult(for: directory) {
        case .success(let root):
            repoRoot = root
        case .notFound:
            return .repositoryNotFound
        case .failed:
            return .gitFailed
        case .timedOut:
            return .gitTimedOut
        }
        // `expectedRepoRoot` identifies the repository returned by the status
        // request. Comparing it directly avoids unsupervised filesystem probes
        // and detects when the workspace starts pointing at another repository.
        guard repoRoot == expectedRepoRoot else {
            return .repositoryChanged
        }
        let diff: GitFileDiff
        switch service.fileDiffResult(
            repoRoot: repoRoot,
            path: path,
            oldPath: oldPath,
            maxOutputBytes: mobileWorkspaceDiffReadCap
        ) {
        case .success(let value):
            diff = value
        case .notFound:
            // The path and optional rename source came from the previous status
            // snapshot. If that exact pair is no longer diffable, make the
            // client refresh status instead of retrying stale row metadata.
            return .repositoryChanged
        case .failed:
            return .gitFailed
        case .timedOut:
            return .gitTimedOut
        }
        let capped = utf8BoundaryCapped(diff.unifiedDiff, byteLimit: mobileWorkspaceDiffFileByteCap)
        return .ok(
            path: diff.path,
            unifiedDiff: capped.text,
            truncated: diff.truncated || capped.truncated
        )
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
        case .gitFailed:
            return .err(code: "git_failed", message: "Could not read repository changes", data: nil)
        case .gitTimedOut:
            return .err(code: "git_timeout", message: "Git took too long to read repository changes", data: nil)
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
        case .repositoryChanged:
            return .err(code: "stale_repository", message: "Workspace repository changed", data: nil)
        case .gitFailed:
            return .err(code: "git_failed", message: "Could not read repository changes", data: nil)
        case .gitTimedOut:
            return .err(code: "git_timeout", message: "Git took too long to read repository changes", data: nil)
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
    case gitFailed
    case gitTimedOut
    case ok(repoRoot: String, files: [GitDiffSummary], truncated: Bool)
}

private enum MobileWorkspaceDiffFileResult: Sendable {
    case repositoryNotFound
    case repositoryChanged
    case gitFailed
    case gitTimedOut
    case ok(path: String, unifiedDiff: String, truncated: Bool)
}
