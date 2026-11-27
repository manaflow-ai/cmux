#if DEBUG
/// DEBUG ONLY (Environment Secrets Playground): one "where to keep it" choice on the agent's secret
/// request card, the same in every direction.
struct EnvRequestScopeChoice: Identifiable {
    var scope: EnvSecretsEntry.Scope
    /// The line under the choice.
    var note: String
    /// A team value needs an admin's person-signed approval (Touch ID on a Mac) before it is saved.
    var needsAdminTouchID: Bool

    var id: Int { scope.rawValue }

    /// Chat first (the default), then Personal, then Team.
    static let all: [EnvRequestScopeChoice] = [
        EnvRequestScopeChoice(scope: .chat, note: EnvSecretsEntry.Scope.chat.caption, needsAdminTouchID: false),
        EnvRequestScopeChoice(scope: .personal, note: EnvSecretsEntry.Scope.personal.caption, needsAdminTouchID: false),
        EnvRequestScopeChoice(scope: .team, note: "Everyone on the team. Needs an admin's Touch ID.", needsAdminTouchID: true),
    ]
}
#endif
