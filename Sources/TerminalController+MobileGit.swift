import CmuxGit
import Foundation

// MARK: - Mobile workspace Git

extension TerminalController {
    func v2MobileWorkspaceGitStatus(params: [String: Any]) async -> V2CallResult {
        guard v2RawString(params, "baseline") == "worktree" else {
            return .err(
                code: "invalid_params",
                message: "Unsupported baseline; supported values: worktree",
                data: ["supported_baselines": ["worktree"]]
            )
        }
        let context = mobileWorkspaceGitContext(params: params)
        if let error = context.error {
            return error
        }
        guard let directory = context.directory else {
            return .err(code: "unavailable", message: "Workspace working directory is unavailable", data: nil)
        }

        do {
            let status = try await WorkspaceGitService().status(forDirectory: directory)
            let files: [[String: Any]] = status.files.map { file in
                var payload: [String: Any] = [
                    "path": file.path,
                    "status": file.status,
                    "additions": file.additions,
                    "deletions": file.deletions,
                    "binary": file.binary,
                    "untracked": file.untracked,
                ]
                if let oldPath = file.oldPath {
                    payload["old_path"] = oldPath
                }
                return payload
            }
            return .ok([
                "repo_root": status.repoRoot,
                "baseline": status.baseline,
                "files": files,
                "total_additions": status.totalAdditions,
                "total_deletions": status.totalDeletions,
            ])
        } catch {
            return mobileWorkspaceGitError(error)
        }
    }

    func v2MobileWorkspaceGitDiff(params: [String: Any]) async -> V2CallResult {
        guard v2RawString(params, "baseline") == "worktree" else {
            return .err(
                code: "invalid_params",
                message: "Unsupported baseline; supported values: worktree",
                data: ["supported_baselines": ["worktree"]]
            )
        }
        guard let paths = params["paths"] as? [String] else {
            return .err(code: "invalid_params", message: "paths must be an array of repository-relative strings", data: nil)
        }
        guard !paths.isEmpty else {
            return .err(code: "invalid_params", message: "paths must contain at least one path", data: ["maximum": 20])
        }
        guard paths.count <= 20 else {
            return .err(code: "invalid_params", message: "paths supports at most 20 entries", data: ["maximum": 20])
        }
        let context = mobileWorkspaceGitContext(params: params)
        if let error = context.error {
            return error
        }
        guard let directory = context.directory else {
            return .err(code: "unavailable", message: "Workspace working directory is unavailable", data: nil)
        }

        do {
            let diff = try await WorkspaceGitService().diff(forDirectory: directory, paths: paths)
            return .ok([
                "baseline": diff.baseline,
                "patch": diff.patch,
                "included": diff.included,
                "truncated": diff.truncated,
                "too_large": diff.tooLarge.map { ["path": $0.path, "bytes": $0.bytes] },
            ])
        } catch {
            return mobileWorkspaceGitError(error)
        }
    }

    private func mobileWorkspaceGitContext(params: [String: Any]) -> (directory: String?, error: V2CallResult?) {
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return (nil, .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return (nil, .err(code: "unavailable", message: "Workspace context is unavailable", data: nil))
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: ["workspace_id": workspaceID.uuidString]
                )
            )
        }
        let directory = workspace.presentedCurrentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory?.isEmpty == false else {
            return (
                nil,
                .err(
                    code: "unavailable",
                    message: "Workspace working directory is unavailable",
                    data: ["workspace_id": workspaceID.uuidString]
                )
            )
        }
        return (directory, nil)
    }

    private func mobileWorkspaceGitError(_ error: any Error) -> V2CallResult {
        guard let gitError = error as? WorkspaceGitServiceError else {
            return .err(code: "git_error", message: "Git operation failed", data: nil)
        }
        switch gitError {
        case .notRepository:
            return .err(code: "not_git_repository", message: "Workspace directory is not inside a Git repository", data: nil)
        case let .commandFailed(operation):
            return .err(code: "git_error", message: "Git operation failed", data: ["operation": operation])
        case let .invalidPath(path):
            return .err(
                code: "invalid_params",
                message: "paths must contain only repository-relative paths",
                data: ["path": path]
            )
        }
    }
}
