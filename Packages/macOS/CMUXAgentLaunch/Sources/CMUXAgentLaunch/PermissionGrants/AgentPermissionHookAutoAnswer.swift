public import Foundation

/// Answers a Claude Code `PermissionRequest` hook from approved grants,
/// before the hook would wait on a Feed card.
///
/// Hook processes only read the grant store and count uses; they never add
/// grants.
public enum AgentPermissionHookAutoAnswer {
    /// The hook output that allows the pending tool call.
    public static let claudeAllowOutput =
        #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#

    private static let userAnswerTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Matches a `PermissionRequest` payload against active grants.
    ///
    /// On a match the grant's use is recorded (best effort) and the allow
    /// output is returned. A missing or unreadable store means no grants.
    /// - Returns: The hook output to print, or `nil` to fall through to the
    ///   normal prompt.
    public static func answerClaudePermissionRequest(
        payload: [String: Any],
        store: AgentPermissionGrantStore,
        now: Date = Date()
    ) -> String? {
        // Plan approvals and questions arrive as PermissionRequest too, but
        // they need the user's answer, not a permission.
        guard let request = AgentPermissionRequest(claudeHookPayload: payload),
              !userAnswerTools.contains(request.toolName),
              let match = store.match(request, sessionID: payload["session_id"] as? String, now: now) else {
            return nil
        }
        try? store.recordUse(of: match.grant.id, now: now)
        return claudeAllowOutput
    }
}
