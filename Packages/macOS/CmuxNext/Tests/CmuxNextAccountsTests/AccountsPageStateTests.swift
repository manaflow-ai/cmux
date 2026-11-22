import CmuxNextCodeRouter
import Foundation
import Testing
@testable import CmuxNextAccounts

/// R82 commit 3: the Accounts screen as data for the React Settings page carries what the SwiftUI
/// view drew (groups, buttons, linked accounts, the confirmation and paste forms), and each page
/// gesture runs the same model call as the view's buttons.
@MainActor @Suite struct AccountsPageStateTests {
    func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    func ready() async -> (AccountsModel, MockAccountsServices) {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        model.refresh()
        await settle { !model.isRefreshing }
        return (model, services)
    }

    @Test func theStateListsGroupsRowsButtonsAndLinkedAccounts() async throws {
        let (model, _) = await ready()
        let state = model.pageState
        #expect(state.groups.map(\.id) == AIProvider.Group.allCases.map(\.rawValue).filter { group in
            !model.rows(in: AIProvider.Group(rawValue: group)!).isEmpty
        })
        let codex = try #require(state.groups.flatMap(\.rows).first { $0.provider == "codex" })
        #expect(codex.statusKind == "success")
        #expect(codex.detail?.contains("~/.codex/auth.json") == true)
        #expect(codex.buttons.contains { $0.id == "connect" })
        #expect(codex.linked.count == 1)
        // The state is JSON the page reads with the same field names.
        let json = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(json.contains("\"statusKind\""))
        #expect(!json.contains("sk-"), "never a secret")
    }

    @Test func pageGesturesRunTheModel() async throws {
        let (model, services) = await ready()
        await model.perform(.connect(.codex))
        #expect(model.pageState.groups.flatMap(\.rows).first { $0.provider == "codex" }?.confirm != nil, "Codex confirms first")
        await model.perform(.cancelConfirm)
        #expect(model.confirmTarget == nil)
        await model.perform(.addKey(.openRouter))
        #expect(model.pageState.groups.flatMap(\.rows).first { $0.provider == "openrouter" }?.paste != nil)
        let error = await model.perform(.saveKey(.openRouter, "   "))
        #expect(error != nil, "an empty key is refused with a message")
        await model.perform(.cancelPaste)
        #expect(model.pasteTarget == nil)
        await model.perform(.signInToCmux)
        #expect(services.calls.contains { $0.hasPrefix("signIn") })
        #expect(AccountsPageAction(action: "remove", provider: nil, account: "", secret: nil) == nil)
        #expect(AccountsPageAction(action: "saveKeychain", provider: "openrouter", account: nil, secret: nil) == nil, "a save needs the secret")
    }
}
