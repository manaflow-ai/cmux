import Foundation

/// Answering a Claude Code `PermissionRequest` hook from approved grants,
/// before the hook would wait on a Feed card.
///
/// The hook never reads grants. It sends the request's matchable fields to
/// the app (`permissions.match`), which answers from
/// ``AgentPermissionGrantRegistry`` with allow or no match, never grant
/// contents. No answer means the normal prompt.
extension AgentPermissionRequest {
    /// The hook output that allows the pending tool call.
    public static let claudeAllowHookOutput =
        #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#

    private static let matchableToolInputKeys = ["command", "file_path", "notebook_path", "path", "url", "pattern"]

    /// The `permissions.match` parameters for a hook payload, or `nil` when
    /// no grant could answer it (plan approvals and questions need the
    /// user's answer, not a permission).
    public static func claudeMatchParams(hookPayload payload: [String: Any]) -> [String: Any]? {
        guard let tool = payload["tool_name"] as? String, !tool.isEmpty,
              !AgentPermissionRuleMatcher.userAnswerTools.contains(tool) else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        var params: [String: Any] = [
            "tool_name": tool,
            "tool_input": input.filter { matchableToolInputKeys.contains($0.key) && $0.value is String },
        ]
        if let cwd = payload["cwd"] as? String { params["cwd"] = cwd }
        if let session = payload["session_id"] as? String { params["session_id"] = session }
        return params
    }

    /// The hook output for a `permissions.match` result, or `nil` to fall
    /// through to the normal prompt.
    public static func claudeHookOutput(forMatchResult result: [String: Any]) -> String? {
        result["allow"] as? Bool == true ? claudeAllowHookOutput : nil
    }
}
