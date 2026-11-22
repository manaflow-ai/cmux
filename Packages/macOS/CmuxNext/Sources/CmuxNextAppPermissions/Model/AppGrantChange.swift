import Foundation

/// Who asks for a grant change. Grants change only from the user (spec
/// 5.2 "user origin only", never MCP); a team admin may only narrow.
public nonisolated enum AppGrantChangeOrigin: String, Sendable, Hashable, Codable {
    case user
    case teamAdmin
    case cli
    case mcp
    case script
    case remote
}

/// The inline first-use prompt's answers.
public nonisolated enum AppFirstUseAnswer: String, Sendable, Hashable, Codable, CaseIterable {
    /// This call only; the grant does not change.
    case allowOnce
    /// Grants the scope (approval by tier default).
    case allow
    /// Turns the scope off; the app is not asked again.
    case deny
}

/// A typed change to one app's grant (the ops `UserDO` / `TeamDO` own).
public nonisolated enum AppGrantChange: Sendable, Hashable {
    /// Turn a declared scope on with an approval mode, or off (`.denied`).
    case setApproval(scope: String, approval: AppScopeApproval)
    case setSelectors(AppResourceSelectors)
    case addFileRoot(AppFileRoot)
    case removeFileRoot(id: String)
    case setProfile(AppSandboxProfile)
    case answerFirstUse(scope: String, answer: AppFirstUseAnswer)
    /// "Revoke all and disable".
    case revokeAll
    /// Re-enable after "Revoke all"; every scope stays off.
    case enable
}
