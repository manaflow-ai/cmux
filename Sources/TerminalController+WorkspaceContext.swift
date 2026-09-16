import Foundation
import CmuxSidebar

extension TerminalController {
    /// User-owned context mutates on the main actor alongside workspace state.
    /// Validate the entire request before writing so a rejected PR cannot change the directory.
    @MainActor
    func applyWorkspaceContext(
        params: [String: Any],
        workspace: Workspace,
        windowID: UUID?
    ) -> V2CallResult {
        let booleanKeys = ["clear_directory", "clear_pull_request"]
        let textKeys = ["pr_url", "pr_label", "pr_state", "pr_branch"]
        guard booleanKeys.allSatisfy({ params[$0] == nil || params[$0] is Bool }),
              textKeys.allSatisfy({ params[$0] == nil || params[$0] is String }) else {
            return .err(code: "invalid_params", message: String(localized: "workspace.context.error.conflict", defaultValue: "Set or clear a directory or pull request; do not set and clear the same field."), data: nil)
        }
        let clearDirectory = params["clear_directory"] as? Bool == true
        let clearPR = params["clear_pull_request"] as? Bool == true
        let hasDirectory = params["workspace_directory"] != nil
        let hasPR = ["pr_number", "pr_url", "pr_label", "pr_state", "pr_branch"].contains { params[$0] != nil }
        guard hasDirectory || hasPR || clearDirectory || clearPR,
              !(hasDirectory && clearDirectory), !(hasPR && clearPR) else {
            return .err(code: "invalid_params", message: String(localized: "workspace.context.error.conflict", defaultValue: "Set or clear a directory or pull request; do not set and clear the same field."), data: nil)
        }

        var directory: String?
        if hasDirectory {
            guard let raw = params["workspace_directory"] as? String,
                  raw.hasPrefix("/"), !raw.contains("\u{0}") else {
                return .err(code: "invalid_params", message: String(localized: "workspace.context.error.directory", defaultValue: "Workspace directory must be an absolute path."), data: nil)
            }
            guard !workspace.usesRemoteDirectoryProvenance else {
                return .err(code: "invalid_params", message: String(localized: "workspace.context.error.remote", defaultValue: "Assigning a workspace directory is supported for local workspaces only."), data: nil)
            }
            directory = NSString(string: raw).standardizingPath
        }

        var pullRequest: SidebarPullRequestState?
        if hasPR {
            guard let number = v2StrictInt(params, "pr_number"), number > 0,
                  let rawURL = params["pr_url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                return .err(code: "invalid_params", message: String(localized: "workspace.context.error.pr", defaultValue: "Pull request requires a positive number and an HTTP or HTTPS URL."), data: nil)
            }
            let label = ((params["pr_label"] as? String) ?? "PR").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  let status = SidebarPullRequestStatus(rawValue: ((params["pr_state"] as? String) ?? "open").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                return .err(code: "invalid_params", message: String(localized: "workspace.context.error.state", defaultValue: "Pull request needs a label and state open, merged, or closed."), data: nil)
            }
            pullRequest = SidebarPullRequestState(number: number, label: String(label.prefix(16)), url: url, status: status, branch: v2String(params, "pr_branch"))
        }

        if hasDirectory || clearDirectory { workspace.setWorkspaceDirectory(directory) }
        if let pullRequest {
            workspace.setWorkspacePullRequest(number: pullRequest.number, label: pullRequest.label, url: pullRequest.url, status: pullRequest.status, branch: pullRequest.branch)
        } else if clearPR {
            workspace.clearWorkspacePullRequest()
        }
        var payload: [String: Any] = [
            "action": "set_context",
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "window_id": v2OrNull(windowID?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowID),
            "workspace_directory": v2OrNull(workspace.workspaceDirectory),
            "pull_request": NSNull()
        ]
        if let pr = workspace.workspacePullRequest {
            payload["pull_request"] = ["number": pr.number, "label": pr.label, "url": pr.url.absoluteString, "status": pr.status.rawValue, "branch": v2OrNull(pr.branch)]
        }
        return .ok(payload)
    }
}
