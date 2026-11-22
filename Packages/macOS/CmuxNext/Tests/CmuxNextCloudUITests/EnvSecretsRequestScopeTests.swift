#if DEBUG
@testable import CmuxNextCloudUI
import Testing

/// Environment Secrets Playground: the agent's secret request card offers the same "where to keep it"
/// choice in every direction (Chat by default, Personal, Team only with an admin's Touch ID), and the
/// card's save button says where the value goes.
@MainActor @Suite struct EnvSecretsRequestScopeTests {
    @Test func requestOffersChatPersonalAndTeamWithChatFirst() {
        let model = EnvSecretsPlaygroundModel()
        #expect(model.requestScopeChoices.map(\.scope) == [.chat, .personal, .team])
        #expect(model.requestScope == .chat)
    }

    @Test func onlyTeamNeedsAnAdminsTouchID() {
        let model = EnvSecretsPlaygroundModel()
        let needs = model.requestScopeChoices.filter(\.needsAdminTouchID).map(\.scope)
        #expect(needs == [.team])
    }

    @Test(arguments: [
        (EnvSecretsEntry.Scope.chat, "Save for this chat"),
        (.personal, "Save for me"),
        (.team, "Ask an admin to approve"),
    ])
    func saveButtonFollowsThePickedScope(scope: EnvSecretsEntry.Scope, title: String) {
        let model = EnvSecretsPlaygroundModel()
        model.requestScope = scope
        #expect(model.requestSaveTitle == title)
    }
}
#endif
