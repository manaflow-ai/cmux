import CmuxNextAccounts
import CmuxNextCodeRouter
import Foundation
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
        // Copilot's sign-in is the editor's, not the GitHub CLI's: nothing here signs it out.
        #expect(AIProvider.copilot.signOutPlan == .none)
        #expect(AIProvider.openAI.signOutPlan == .none)
    }

    @Test func onlyTheSignInTheLogoutRemovesOffersSignOut() {
        #expect(AIProvider.codex.signOutRemoves(.file("~/.codex/auth.json")))
        #expect(AIProvider.codex.signOutRemoves(.keychain("Codex Auth")))
        #expect(!AIProvider.codex.signOutRemoves(.providerConfig("~/.codex/config.toml")))
        #expect(AIProvider.claude.signOutRemoves(.file("~/.claude/.credentials.json")))
        #expect(AIProvider.claude.signOutRemoves(.keychain("Claude Code-credentials")))
        // A settings.json key or helper and a saved API key outlive `claude auth logout`.
        #expect(!AIProvider.claude.signOutRemoves(.file("~/.claude/settings.json")))
        #expect(!AIProvider.claude.signOutRemoves(.file("~/.claude.json")))
        #expect(!AIProvider.copilot.signOutRemoves(.file("~/.config/github-copilot/apps.json")))
    }

    @Test func aClaudeSettingsHelperHasNoSignOut() async {
        let services = MockAccountsServices()
        services.detections.removeAll { $0.provider == .claude }
        services.detections.append(ProviderDetection(provider: .claude, status: .signedIn, detail: "apiKeyHelper",
                                                     sources: [.file("~/.claude/settings.json")]))
        let model = await refreshed(services)
        #expect(row(model, .claude)?.buttons.map(\.id).contains("signOut") == false)
        await model.signOut(.claude)
        #expect(!services.calls.contains("signOut:claude"))
    }

    @Test func withNoLocalPaneTheRowIsFreedAndSaysWhy() async {
        let services = MockAccountsServices()
        services.opensTabs = false
        let model = await refreshed(services)

        let refusal = await model.perform(.signOut(.codex))
        #expect(services.calls.contains("signOut:codex"))
        #expect(refusal?.hasPrefix("Open a workspace on this Mac") == true)
        #expect(model.row(.codex).phase == .idle)
        #expect(model.row(.codex).outcome == .failed(refusal ?? ""))

        #expect(await model.reauthenticate(.claude) == refusal)
        #expect(model.row(.claude).phase == .idle)
        // Nothing is pending, so coming back to Settings does not re-detect.
        let detections = services.calls.filter { $0 == "detect" }.count
        await model.perform(.windowFocused)
        #expect(services.calls.filter { $0 == "detect" }.count == detections)
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

        // The logout ran in a cmux tab, so the app stayed active: coming back
        // to the Settings window re-detects and frees the row.
        let detections = services.calls.filter { $0 == "detect" }.count
        await model.perform(.windowFocused)
        for _ in 0..<200 where model.isRefreshing { await Task.yield() }
        #expect(model.row(.codex).phase != .reauthenticating)
        #expect(services.calls.filter { $0 == "detect" }.count == detections + 1)
        #expect(AccountsPageAction(action: "focus", provider: nil, account: nil, secret: nil) == .windowFocused)
    }

    @Test func aShellVariableSignInHasNoSignOutAndSaysWhy() async {
        let services = MockAccountsServices()
        services.detections.removeAll { $0.provider == .claude }
        services.detections.append(ProviderDetection(provider: .claude, status: .signedIn,
                                                     sources: [.environment("CLAUDE_CODE_OAUTH_TOKEN")]))
        let model = await refreshed(services)
        let claude = row(model, .claude)
        #expect(claude?.buttons.map(\.id).contains("signOut") == false)
        #expect(claude?.note?.hasPrefix("Your shell provides this sign-in") == true)

        await model.signOut(.claude)
        #expect(!services.calls.contains("signOut:claude"))
    }
}
