/// The issue-inbox domain slice of the control-command seam.
@MainActor
public protocol ControlIssuesContext: AnyObject {
    /// Snapshots cached Issue Inbox items.
    func controlIssuesList() -> ControlCallResult

    /// Opens or focuses the Issue Inbox surface.
    ///
    /// - Parameter params: Raw typed params for normal v2 routing.
    func controlIssuesOpen(params: [String: JSONValue]) -> ControlCallResult

    /// Creates or reuses a workspace for one issue.
    ///
    /// - Parameters:
    ///   - issueID: Stable issue ID.
    ///   - cwd: Optional explicit working directory.
    ///   - params: Raw typed params for normal v2 routing.
    func controlIssuesSpawnWorkspace(
        issueID: String,
        cwd: String?,
        params: [String: JSONValue]
    ) -> ControlCallResult
}

public extension ControlIssuesContext {
    func controlIssuesList() -> ControlCallResult {
        .err(code: "method_not_found", message: "Issue Inbox is not available in this context", data: nil)
    }

    func controlIssuesOpen(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "method_not_found", message: "Issue Inbox is not available in this context", data: nil)
    }

    func controlIssuesSpawnWorkspace(
        issueID: String,
        cwd: String?,
        params: [String: JSONValue]
    ) -> ControlCallResult {
        .err(code: "method_not_found", message: "Issue Inbox is not available in this context", data: nil)
    }
}
