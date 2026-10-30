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

    /// A saved key reads signed in by its presence alone, so a key Connect would refuse
    /// (`CredentialResolver.isWellFormedKey`) is refused at Save instead of saved.
    @Test func aMalformedKeyIsNotSavedToTheKeychain() {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        #expect(model.saveKey("short", for: .openAI) != nil)
        #expect(model.saveKey("abcdefghijklmnopqrstuvwxyz0123", for: .anthropic) != nil)
        #expect(!services.calls.contains { $0.hasPrefix("saveKey:") })
        #expect(model.saveKey("  sk-ant-api03-abcdefghijklmnopqrstuvwxyz \n", for: .anthropic) == nil)
        #expect(services.calls.contains("saveKey:anthropic"))
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
        let failure = await model.performReauthenticate(.codex)
        #expect(failure == nil)
        #expect(services.calls.contains("reauth:codex"))
    }

    /// The page's Sign In Again waits for detection and starts the login
    /// before it answers, so its answer is the real outcome.
    @Test func aPageReauthenticateBeforeTheScreenEverOpenedStartsTheLoginBeforeAnswering() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        let failure = await model.perform(.reauthenticate(.codex))
        #expect(failure == nil)
        #expect(services.calls.contains("reauth:codex"))
    }

    /// While detection runs every row is Checking…; a reauthenticate that
    /// cannot wait says so instead of answering success and starting a
    /// login later that nothing owns.
    @Test func aReauthenticateThatCannotWaitWhileCheckingSaysSo() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        #expect(model.reauthenticate(.codex) != nil)
        await model.settle()
        #expect(!services.calls.contains("reauth:codex"))
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

    @Test func aReauthenticateWhileTheRowIsBusySaysSo() async {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        model.connect(.codex, confirmed: true)
        #expect(model.row(.codex).phase == .connecting)
        #expect(model.reauthenticate(.codex) != nil)
        #expect(!services.calls.contains("reauth:codex"))
    }

    /// A login in a cmux tab never makes the app inactive, so its row stays
    /// Re-authenticating; the next CLI action re-detects instead of refusing.
    @Test func aRemoveAfterALoginInATabReDetectsAndRemoves() async throws {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        model.reauthenticate(.codex)
        #expect(model.row(.codex).phase == .reauthenticating)
        let account = try #require(await model.linkedAccount(id: linkedID))
        let failure = await model.performRemove(account)
        #expect(failure == nil)
        #expect(services.calls.contains("remove:\(linkedID)"))
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
