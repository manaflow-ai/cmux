import CmuxNextAccounts
import CmuxNextCodeRouter
import Foundation
import Testing

/// After CodeRouter answered a Connect or Remove, the screen reloads the
/// account list. A reload that fails keeps the accounts it already showed
/// instead of showing none.
@MainActor
@Suite struct AccountsListReloadTests {
    private let firstID = "11111111-1111-4111-8111-111111111111"
    private let secondID = "22222222-2222-4222-8222-222222222222"

    private func refreshed(_ services: MockAccountsServices) async -> AccountsModel {
        let model = AccountsModel(services: services)
        model.refresh()
        for _ in 0..<200 where model.isRefreshing { await Task.yield() }
        return model
    }

    private func secondCodexAccount() -> LinkedAccount {
        LinkedAccount(id: secondID, family: .native, provider: .codex,
                      account: AccountLabel.demo("codex-2", display: "team"), state: "active")
    }

    @Test func aRemoveWhoseReloadFailsKeepsTheOtherAccounts() async throws {
        let services = MockAccountsServices()
        services.linked.append(secondCodexAccount())
        let model = await refreshed(services)
        #expect(model.row(.codex).linked.count == 2)
        let first = try #require(model.row(.codex).linked.first { $0.id == firstID })

        services.linkedFailure = URLError(.timedOut)
        let failure = await model.performRemove(first)
        #expect(failure == nil)
        #expect(model.row(.codex).linked.map(\.id) == [secondID])
        #expect(model.row(.codex).outcome == .removed)
    }

    @Test func aConnectWhoseReloadFailsKeepsTheAccountsAlreadyShown() async {
        let services = MockAccountsServices()
        let model = await refreshed(services)
        #expect(model.row(.codex).linked.map(\.id) == [firstID])

        services.linkedFailure = URLError(.timedOut)
        model.connect(.codex, confirmed: true)
        for _ in 0..<200 where model.row(.codex).phase == .connecting { await Task.yield() }
        #expect(model.row(.codex).outcome == .connected)
        #expect(model.row(.codex).linked.contains { $0.id == firstID })
    }
}
