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
        await model.settle()
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
        #expect(await model.reauthenticate(.codex) != nil)
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
        #expect(await model.reauthenticate(.codex) != nil)
        #expect(!services.calls.contains("reauth:codex"))
    }

    /// A login in a cmux tab never makes the app inactive, so its row stays
    /// Re-authenticating; the next CLI action re-detects instead of refusing.
    @Test func aRemoveAfterALoginInATabReDetectsAndRemoves() async throws {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        await model.reauthenticate(.codex)
        #expect(model.row(.codex).phase == .reauthenticating)
        let account = try #require(await model.linkedAccount(id: linkedID))
        let failure = await model.performRemove(account)
        #expect(failure == nil)
        #expect(services.calls.contains("remove:\(linkedID)"))
    }

    @Test(arguments: [true, false])
    func aReauthenticateWaitsForWorkspaceCreationAndReportsItsResult(opened: Bool) async {
        let services = MockAccountsServices()
        let started = AsyncStream<Void>.makeStream()
        var answer: CheckedContinuation<Bool, Never>?
        services.openProviderTab = { _ in
            await withCheckedContinuation { continuation in
                answer = continuation
                started.continuation.yield(())
                started.continuation.finish()
            }
        }
        let model = await refreshed(services)
        var completed = false
        let action = Task { @MainActor in
            let result = await model.perform(.reauthenticate(.codex))
            completed = true
            return result
        }
        for await _ in started.stream { break }
        #expect(!completed, "the action answered before the workspace opened")
        model.refresh()
        await model.settle()
        #expect(model.row(.codex).phase == .reauthenticating, "refresh cleared the in-flight login")
        #expect(await model.reauthenticate(.codex) != nil, "a second click started another pending workspace")
        answer?.resume(returning: opened)
        let failure = await action.value
        #expect((failure == nil) == opened)
        #expect(model.row(.codex).phase == (opened ? .reauthenticating : .idle))
    }

    /// A refresh may have started before the provider login opens its tab. Its
    /// detection result must not clear the row after the tab opener returns,
    /// while that older refresh is still delivering its result.
    @Test func aRefreshStartedBeforeLoginCannotClearTheBusyRow() async {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        let detectionStarted = AsyncStream<Void>.makeStream()
        var releaseDetection: CheckedContinuation<Void, Never>?
        services.beforeDetect = {
            detectionStarted.continuation.yield(())
            detectionStarted.continuation.finish()
            await withCheckedContinuation { continuation in
                releaseDetection = continuation
            }
        }
        let loginStarted = AsyncStream<Void>.makeStream()
        var finishLogin: CheckedContinuation<Bool, Never>?
        services.openProviderTab = { _ in
            loginStarted.continuation.yield(())
            loginStarted.continuation.finish()
            return await withCheckedContinuation { continuation in
                finishLogin = continuation
            }
        }

        model.refresh()
        for await _ in detectionStarted.stream { break }
        let login = Task { @MainActor in await model.reauthenticate(.codex) }
        for await _ in loginStarted.stream { break }
        finishLogin?.resume(returning: true)
        #expect(await login.value == nil)
        #expect(model.row(.codex).phase == .reauthenticating)

        releaseDetection?.resume()
        await model.settle()
        #expect(!model.isRefreshing)
        #expect(model.row(.codex).phase == .reauthenticating)
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
