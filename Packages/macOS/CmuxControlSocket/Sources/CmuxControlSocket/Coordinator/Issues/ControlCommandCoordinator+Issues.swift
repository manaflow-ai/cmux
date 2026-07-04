internal import Foundation

/// The Issue Inbox control domain.
extension ControlCommandCoordinator {
    /// Dispatches Issue Inbox methods owned by the coordinator.
    ///
    /// `issues.refresh` stays on the app-side socket-worker path because it can
    /// wait on provider network requests.
    func handleIssues(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "issues.list":
            return context?.controlIssuesList()
                ?? .err(code: "unavailable", message: "Issue Inbox is unavailable", data: nil)
        case "issues.open":
            return context?.controlIssuesOpen(params: request.params)
                ?? .err(code: "unavailable", message: "Issue Inbox is unavailable", data: nil)
        case "issues.spawn_workspace":
            return issuesSpawnWorkspace(request.params)
        default:
            return nil
        }
    }

    private func issuesSpawnWorkspace(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let rawIssueID = rawString(params, "issue_id") else {
            return .err(code: "invalid_params", message: "issues.spawn_workspace requires issue_id", data: nil)
        }
        let issueID = rawIssueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issueID.isEmpty else {
            return .err(code: "invalid_params", message: "issues.spawn_workspace requires issue_id", data: nil)
        }
        if let rawCwd = params["cwd"], case .null = rawCwd {
            return context?.controlIssuesSpawnWorkspace(issueID: issueID, cwd: nil, params: params)
                ?? .err(code: "unavailable", message: "Issue Inbox is unavailable", data: nil)
        }
        if params["cwd"] != nil, rawString(params, "cwd") == nil {
            return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
        }
        let cwd = optionalTrimmedRawString(params, "cwd")
        return context?.controlIssuesSpawnWorkspace(issueID: issueID, cwd: cwd, params: params)
            ?? .err(code: "unavailable", message: "Issue Inbox is unavailable", data: nil)
    }
}
