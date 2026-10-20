import CmuxNextAccounts
import CmuxNextCodeRouter
import Testing

/// `cmux accounts connect/remove/reauthenticate` and the palette act through
/// `AccountsModel`, often before Settings > Accounts ever opened. An action
/// either does its work or says why it did not; it never answers success
/// for work it skipped.
@MainActor
@Suite struct AccountsActionOutcomeTests {
    private let linkedID = "11111111-1111-4111-8111-111111111111"

    private func refreshed(_ services: MockAccountsServices) async -> AccountsModel {
        let model = AccountsModel(services: services)
        model.refresh()
        for _ in 0..<200 where model.isRefreshing { await Task.yield() }
        return model
    }

    @Test func aRemoveBeforeTheScreenEverOpenedRemovesTheAccount() async throws {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        let account = try #require(await model.linkedAccount(id: linkedID))
        let failure = await model.performRemove(account)
        #expect(failure == nil)
        #expect(services.calls.contains("remove:\(linkedID)"))
    }

    @Test func aConnectBeforeTheScreenEverOpenedConnects() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        let failure = await model.performConnect(.anthropic)
        #expect(failure == nil)
        #expect(services.calls.contains("connect:anthropic:local"))
    }

    @Test func aReauthenticateBeforeTheScreenEverOpenedStartsTheLogin() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.reauthenticate(.codex)
        for _ in 0..<200 where !services.calls.contains("reauth:codex") { await Task.yield() }
        #expect(services.calls.contains("reauth:codex"))
    }

    @Test func aConnectWhileTheRowIsBusySaysSo() async {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        model.connect(.anthropic)
        #expect(model.row(.anthropic).phase == .connecting)
        let failure = await model.performConnect(.anthropic)
        #expect(failure != nil)
    }

    @Test func aRemoveWhileTheRowIsBusySaysSo() async throws {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        let account = try #require(await model.linkedAccount(id: linkedID))
        model.remove(account)
        let failure = await model.performRemove(account)
        #expect(failure != nil)
    }

    @Test func aCodexConnectWithoutACodexSignInNamesCodexNotCmux() async {
        let services = MockAccountsServices()
        services.detections.removeAll { $0.provider == .codex }
        let model = await refreshed(services)
        #expect(model.isSignedInToCmux)
        let failure = await model.performConnect(.codex)
        #expect(failure?.contains(AIProvider.codex.displayName) == true)
        #expect(!services.calls.contains { $0.hasPrefix("connect:codex") })
    }
}
