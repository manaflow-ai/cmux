import CmuxNextCodeRouter
import Foundation
import Testing
@testable import CmuxNextAccounts

@MainActor @Suite struct AccountsModelTests {
    /// Waits for the model's async work: each step yields until `done` or 200 turns pass.
    func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func refreshFillsRowsAndLinks() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        #expect(model.row(.codex).status == .signedIn)
        #expect(model.row(.codex).linked.count == 1)
        #expect(model.row(.xai).status == .missing)
        #expect(model.row(.ollama).phase == .idle)
        #expect(model.rows(in: .other).contains { $0.provider == .openCodeGo } == false)
    }

    @Test func connectWithLocalSignIn() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        model.connect(.codex)
        #expect(model.confirmTarget == .codex, "Codex shows the refresh-token note first")
        #expect(model.row(.codex).phase == .idle)
        model.connect(.codex, confirmed: true)
        #expect(model.row(.codex).phase == .connecting)
        await settle { model.row(.codex).phase == .idle }
        #expect(services.calls.contains("connect:codex:local"))
        #expect(model.row(.codex).outcome == .connected)
        #expect(model.row(.codex).linked.count == 2)
    }

    @Test func claudeConnectAsksForPasteFirst() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        model.connect(.claude)
        #expect(model.pasteTarget == .claude)
        #expect(!services.calls.contains { $0.hasPrefix("connect:") })
        model.connect(.claude, pasted: "sk-ant-oat01-fixture")
        await settle { model.row(.claude).phase == .idle }
        #expect(services.calls.contains("connect:claude:pasted"))
    }

    @Test func failuresShowServerMessage() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        services.failure = CodeRouterError.http(status: 400, code: "invalid_credential", message: "Sign in to Codex again.")
        model.connect(.codex, confirmed: true)
        await settle { model.row(.codex).phase == .idle }
        guard case .failed(let text) = model.row(.codex).outcome else { Issue.record("expected failure"); return }
        #expect(text.contains("Sign in to Codex again."))
    }

    @Test func signedOutBlocksConnectAndSkipsCodeRouter() async {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        #expect(!services.calls.contains("linked"))
        #expect(!model.row(.codex).canConnect)
        model.connect(.codex)
        #expect(model.row(.codex).phase == .idle)
    }

    /// Leo, 2026-10-06: signed out, Accounts shows one "Sign In to cmux"
    /// button at the top and no sentence about CodeRouter, in the banner or
    /// in Connect's tooltip.
    @Test func signedOutIsOneSignInButton() async throws {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        let data = try JSONEncoder().encode(model.pageState)
        let page = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(page["signIn"] as? String == AccountsStrings.signInToCmux)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("CodeRouter, so"), "an explanation is still on the page")
    }

    /// Controls that cannot run are hidden, not greyed out or explained:
    /// signed out, no row offers Connect, and no row says CodeRouter does
    /// not route its provider.
    @Test func rowsOfferOnlyWhatCanRun() async throws {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        let rows = model.pageState.groups.flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { row in !row.buttons.contains { $0.id == "connect" } })
        let text = String(decoding: try JSONEncoder().encode(model.pageState), as: UTF8.self)
        #expect(!text.contains("does not route"))
    }

    @Test func reauthRedetectsOnActivation() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        model.reauthenticate(.codex)
        #expect(services.calls.contains("reauth:codex"))
        #expect(model.row(.codex).phase == .reauthenticating)
        let detects = services.calls.filter { $0 == "detect" }.count
        model.appDidBecomeActive()
        await settle { !model.isRefreshing }
        #expect(services.calls.filter { $0 == "detect" }.count == detects + 1)
        #expect(model.row(.codex).phase == .idle)
    }

    @Test func removeAndSaveKey() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        let account = model.row(.codex).linked[0]
        model.remove(account)
        await settle { model.row(.codex).phase == .idle }
        #expect(model.row(.codex).linked.isEmpty)
        #expect(model.saveKey("  ", for: .groq) != nil)
        #expect(model.saveKey("gsk_fixture_0000000000000000", for: .groq) == nil)
        await settle { !model.isRefreshing }
        #expect(model.row(.groq).detection?.sources == [.cmuxKeychain])
    }
}

@MainActor @Suite struct AccountsStepViewTests {
    /// Onboarding lists the four agent providers and only the others found here.
    @Test func stepListsAgentProvidersAndDetectedOthers() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        for _ in 0..<200 where model.isRefreshing { await Task.yield() }
        let shown = AccountsStepView(model: model, palette: .app).rows.map(\.provider)
        #expect(shown == [.codex, .openAI, .claude, .anthropic, .gemini, .ollama])
    }
}
