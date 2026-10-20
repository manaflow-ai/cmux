import CmuxNextAccounts
import CmuxNextCodeRouter
import Testing

/// Settings > Accounts: Sign Out per provider runs the provider's own logout,
/// and a sign-in that comes from a shell variable says so instead.
@MainActor
@Suite struct AccountsSignOutTests {
    private func refreshed(_ services: MockAccountsServices) async -> AccountsModel {
        let model = AccountsModel(services: services)
        model.refresh()
        for _ in 0..<200 where model.isRefreshing { await Task.yield() }
        return model
    }

    private func row(_ model: AccountsModel, _ provider: AIProvider) -> AccountsPageState.Row? {
        model.pageState.groups.lazy.flatMap(\.rows).first { $0.provider == provider.rawValue }
    }

    @Test func theLogoutCommandsAreTheCLIsOwn() {
        #expect(AIProvider.codex.signOutPlan.shellLine == "codex logout")
        #expect(AIProvider.claude.signOutPlan.shellLine == "claude auth logout")
        #expect(AIProvider.copilot.signOutPlan.shellLine == "gh auth logout")
        #expect(AIProvider.openAI.signOutPlan == .none)
    }

    @Test func aPlanTypesItsLineOrOpensItsPage() throws {
        var lines: [String] = [], pages: [URL] = []
        let page = try #require(URL(string: "https://console.anthropic.com/settings/keys"))
        for plan in [AIProvider.codex.signOutPlan, .page(page), .none] {
            plan.run(line: { lines.append($0) }, page: { pages.append($0) })
        }
        #expect(lines == ["codex logout"])
        #expect(pages == [page])
    }

    @Test func aSavedSignInOffersSignOutAndRunsTheLogout() async {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        let codex = row(model, .codex)
        #expect(codex?.buttons.map(\.id).contains("signOut") == true)
        #expect(codex?.buttons.first { $0.id == "signOut" }?.destructive == true)

        let action = AccountsPageAction(action: "signOut", provider: "codex", account: nil, secret: nil)
        #expect(action == .signOut(.codex))
        if let action { await model.perform(action) }
        #expect(services.calls.contains("signOut:codex"))
        #expect(model.row(.codex).phase == .reauthenticating)
    }

    @Test func aShellVariableSignInHasNoSignOutAndSaysWhy() async {
        let services = MockAccountsServices()
        services.detections.removeAll { $0.provider == .claude }
        services.detections.append(ProviderDetection(provider: .claude, status: .signedIn,
                                                     sources: [.environment("CLAUDE_CODE_OAUTH_TOKEN")]))
        let model = await refreshed(services)
        let claude = row(model, .claude)
        #expect(claude?.buttons.map(\.id).contains("signOut") == false)
        #expect(claude?.note?.contains("$CLAUDE_CODE_OAUTH_TOKEN") == true)

        model.signOut(.claude)
        #expect(!services.calls.contains("signOut:claude"))
    }
}
