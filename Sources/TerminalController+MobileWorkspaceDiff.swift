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

    /// Socket-policy justification (skills/cmux-socket-policy): this wrapper and
    /// `v2MobileWorkspaceDiffFileForControlSocket` run their git work synchronously
    /// on the main actor because the v2 control socket's mobile-host seam
    /// (`ControlMobileHostContext`) is a synchronous `@MainActor` protocol invoked
    /// from the sync `processV2Command` path; a sync witness cannot await the
    /// detached off-main variants without blocking the main thread anyway. These
    /// are per-request debug/CLI verbs, not telemetry hot paths (`report_*`-class),
    /// and the git subprocesses are short-lived with output capped at
    /// `mobileWorkspaceDiffByteCap`. The iOS data plane (`mobileHostHandleRPC`)
    /// uses the async `v2MobileWorkspaceDiffStatus` / `v2MobileWorkspaceDiffFile`
    /// bodies above, which run the same git work off-main in a detached utility task.
    func v2MobileWorkspaceDiffStatusForControlSocket(params: [String: Any]) -> V2CallResult {
        switch mobileWorkspaceDiffSnapshot(params: params) {
        case .failure(let error):
            return error
        case .success(let snapshot):
            return Self.v2MobileWorkspaceDiffResult(
                Self.mobileWorkspaceDiffStatusResultSync(directory: snapshot.directory)
            )
        }
    }

    func v2MobileWorkspaceDiffFileForControlSocket(params: [String: Any]) -> V2CallResult {
        guard let rawPath = params["path"] as? String,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid path", data: nil)
        }
        switch mobileWorkspaceDiffSnapshot(params: params) {
        case .failure(let error):
            return error
        case .success(let snapshot):
            return Self.v2MobileWorkspaceDiffResult(
                Self.mobileWorkspaceDiffFileResultSync(directory: snapshot.directory, path: rawPath)
            )
        }
    }

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
        await Task.detached(priority: .utility) {
            mobileWorkspaceDiffStatusResultSync(directory: directory)
        }.value
    }

    private nonisolated static func mobileWorkspaceDiffFileResult(directory: String, path: String) async -> MobileWorkspaceDiffFileResult {
        await Task.detached(priority: .utility) {
            mobileWorkspaceDiffFileResultSync(directory: directory, path: path)
        }.value
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
