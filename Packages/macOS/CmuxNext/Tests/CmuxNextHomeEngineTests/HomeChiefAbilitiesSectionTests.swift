import AppKit
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Observation
import Testing

/// The Chief Settings card's Vault and Connections sections (cmux issue 34263): hidden until the
/// app gives them a source, the vault shows names only, and the connection rows follow the model
/// while the card is open and offer only the gesture that applies.
@MainActor @Suite(.serialized) struct HomeChiefAbilitiesSectionTests {
    @Test func bothSectionsStayHiddenWithoutASource() {
        let home = FileManager.default.temporaryDirectory
        let card = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        card.vault.open()
        card.connections.open()
        #expect(card.vault.isHidden)
        #expect(card.connections.isHidden)
    }

    @Test func theVaultListsNamesAndSaysWhenItIsEmptyOrUnreadable() async {
        let section = HomeChiefVaultSection()
        section.show(["OPENAI_API_KEY", "STRIPE_KEY"])
        #expect(section.summary.stringValue.contains("OPENAI_API_KEY, STRIPE_KEY"))
        #expect(section.summary.stringValue.hasPrefix("2"))
        section.show([])
        #expect(section.summary.stringValue == HomeEngineStrings.vaultEmpty)
        section.show(nil)
        #expect(section.summary.stringValue == HomeEngineStrings.vaultUnreadable)
    }

    @Test func theVaultReadsWhenTheCardOpens() async {
        let section = HomeChiefVaultSection()
        let reads = Counter()
        section.names = { await reads.add(); return ["GITHUB_TOKEN"] }
        #expect(!section.isHidden)
        #expect(await reads.value == 0)
        section.open()
        await section.settled()
        #expect(await reads.value == 1)
        #expect(section.summary.stringValue.contains("GITHUB_TOKEN"))
    }

    @Test func rowsFollowTheModelAndOfferOnlyTheGestureThatApplies() async {
        let model = Model()
        let section = HomeChiefConnectionsSection()
        var acts: [(HomeChiefConnection.Provider, Bool)] = []
        var refreshes = 0
        section.source = .init(rows: { (model.rows, model.failed) }, refresh: { refreshes += 1 }, act: { acts.append(($0, $1)) })
        section.open()
        #expect(!section.isHidden)
        #expect(refreshes == 1)
        #expect(section.shown.map(\.action) == [.connect, .connect])
        model.rows[0] = HomeChiefConnection(provider: .gmail, state: .connected(account: "me@example.com"), canDisconnect: true, working: false)
        await section.settledOn { $0.shown.first?.state == .connected(account: "me@example.com") }
        #expect(section.shown.first?.action == .disconnect)
        #expect(section.shown.first?.status == "me@example.com")
        // A teammate's shared connection shows its account but no Disconnect.
        model.rows[1] = HomeChiefConnection(provider: .googleCalendar, state: .connected(account: "team@example.com"), canDisconnect: false, working: false)
        await section.settledOn { $0.shown.last?.state == .connected(account: "team@example.com") }
        #expect(section.shown.last?.action == nil)
        #expect(HomeChiefConnection(provider: .gmail, state: .signedOut, canDisconnect: false, working: false).action == nil)
        #expect(HomeChiefConnection(provider: .gmail, state: .needsReauth, canDisconnect: true, working: false).action == .reconnect)
        #expect(HomeChiefConnection(provider: .gmail, state: .notConnected, canDisconnect: false, working: true).action == nil)
        section.close()
        #expect(acts.isEmpty)
    }

    @Observable @MainActor final class Model {
        var rows = HomeChiefConnection.Provider.allCases.map { HomeChiefConnection(provider: $0, state: .notConnected, canDisconnect: false, working: false) }
        var failed = false
    }

    actor Counter {
        var value = 0
        func add() { value += 1 }
    }
}

extension HomeChiefVaultSection {
    /// Waits for the open card's read to show.
    func settled() async {
        for _ in 0..<1000 where shown == nil { await Task.yield() }
    }
}

extension HomeChiefConnectionsSection {
    /// Waits for the observation stream to deliver a state that passes `check`.
    func settledOn(_ check: (HomeChiefConnectionsSection) -> Bool) async {
        for _ in 0..<1000 where !check(self) { await Task.yield() }
    }
}
