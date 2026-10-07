import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app's view of the cmux model catalog (decision M2) as a thin acpmux client: it reads
/// `catalog.get`, asks `catalog.refresh` only for a refresh with the remote catalog on, keeps the
/// last good answer when acpmux cannot reply, and never fetches over HTTP itself.
@Suite struct AgentModelCatalogStoreTests {
    private static func catalog(_ generatedAt: String) -> JSONValue {
        ["schemaVersion": .number(1), "generatedAt": .string(generatedAt), "source": .string("live"),
         "harnesses": .array([["id": .string("claude"), "name": .string("Claude Code"), "brand": .string("claude"),
                               "families": .array([.string("claude")]), "modelSource": .string("catalog"), "models": .array([])]]),
         "models": .object([:]), "providers": .object([:])]
    }

    /// A scripted acpmux: each `catalog.get` takes the next answer; calls are counted.
    private actor Acpmux: AgentModelCatalogSource {
        private var answers: [Result<JSONValue, any Error>]
        private(set) var gets = 0
        private(set) var refreshes = 0
        init(_ answers: [Result<JSONValue, any Error>]) { self.answers = answers }
        func get() async throws -> JSONValue {
            gets += 1
            return try (answers.isEmpty ? .failure(AcpmuxStatusClient.Failure.closed) : answers.removeFirst()).get()
        }
        func refresh() async throws -> JSONValue {
            refreshes += 1
            return ["changed": .bool(true)]
        }
    }

    private static func reply(_ catalog: JSONValue, delivery: String) -> Result<JSONValue, any Error> {
        .success(["catalog": catalog, "delivery": .string(delivery), "schemaVersion": .number(1)])
    }

    @Test func theCatalogComesFromAcpmuxWithItsDelivery() async {
        let acpmux = Acpmux([Self.reply(Self.catalog("2026-10-07T00:00:00Z"), delivery: "fetched"),
                             Self.reply(Self.catalog("2026-10-07T00:00:00Z"), delivery: "stored")])
        let store = AgentModelCatalogStore(source: acpmux)
        let first = await store.current(refresh: false, remote: true)
        #expect(first.catalog?["schemaVersion"] == .number(1))
        #expect(first.delivery == "network")
        #expect(first.changed)
        let second = await store.current(refresh: false, remote: true)
        #expect(second.delivery == "disk")
        #expect(!second.changed, "the same catalog is no change")
        #expect(await acpmux.refreshes == 0)
    }

    @Test func aRefreshAsksAcpmuxToFetchAndANewCatalogIsAChange() async {
        let acpmux = Acpmux([Self.reply(Self.catalog("2026-10-07T00:00:00Z"), delivery: "bundled"),
                             Self.reply(Self.catalog("2026-10-07T06:00:00Z"), delivery: "fetched")])
        let store = AgentModelCatalogStore(source: acpmux)
        _ = await store.current(refresh: false, remote: true)
        let refreshed = await store.current(refresh: true, remote: true)
        #expect(await acpmux.refreshes == 1)
        #expect(refreshed.changed)
        #expect(refreshed.catalog?["generatedAt"] == .string("2026-10-07T06:00:00Z"))
    }

    @Test func remoteOffNeverAsksAcpmuxToFetch() async {
        let acpmux = Acpmux([Self.reply(Self.catalog("2026-10-07T00:00:00Z"), delivery: "stored")])
        let result = await AgentModelCatalogStore(source: acpmux).current(refresh: true, remote: false)
        #expect(await acpmux.refreshes == 0)
        #expect(result.catalog != nil)
    }

    @Test func whenAcpmuxCannotAnswerTheLastCatalogStandsAndABadOneNeverReplacesIt() async {
        let acpmux = Acpmux([
            Self.reply(Self.catalog("2026-10-07T00:00:00Z"), delivery: "fetched"),
            .success(["catalog": ["schemaVersion": .number(2)], "delivery": .string("fetched")]),
            .failure(AcpmuxStatusClient.Failure.unreachable("no socket")),
        ])
        let store = AgentModelCatalogStore(source: acpmux)
        _ = await store.current(refresh: false, remote: true)
        let afterBad = await store.current(refresh: false, remote: true)
        #expect(afterBad.catalog?["schemaVersion"] == .number(1))
        let afterDown = await store.current(refresh: false, remote: true)
        #expect(afterDown.catalog?["generatedAt"] == .string("2026-10-07T00:00:00Z"))
        #expect(!afterDown.changed)

        let empty = await AgentModelCatalogStore(source: Acpmux([])).current(refresh: false, remote: true)
        #expect(empty.catalog == nil)
        #expect(empty.delivery == nil)
        let none = await AgentModelCatalogStore(source: nil).current(refresh: true, remote: true)
        #expect(none.catalog == nil)
    }

    @Test func theWatcherSeesOnlyCatalogChangedNotifications() {
        let reader = LineReader()
        let lines = reader.append(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8) + Data([0x0A])
            + Data(#"{"jsonrpc":"2.0","method":"catalog.changed","params":{"schemaVersion":1}}"#.utf8) + Data([0x0A])
            + Data(#"{"jsonrpc":"2.0","method":"_acpmux/sess"#.utf8))
        #expect(lines.map(AcpmuxCatalogWatcher.isChanged) == [false, true])
        let rest = reader.append(Data(#"ion_changed","params":{}}"#.utf8) + Data([0x0A]))
        #expect(rest.map(AcpmuxCatalogWatcher.isChanged) == [false])
    }

    @Test func thePageAsksForTheCatalogByMethodName() {
        #expect(AgentPaneRequest(body: ["method": "models.catalog", "params": [:]] as [String: Any]) == .modelCatalog(refresh: false))
        #expect(AgentPaneRequest(body: ["method": "models.catalog", "params": ["refresh": true]] as [String: Any]) == .modelCatalog(refresh: true))
        #expect(AgentPageOps.all.contains("cmux.agent.models.catalog"))
    }

    @Test func theHostReplyCarriesCatalogDeliveryAndTheUserLayer() {
        let user: JSONValue = ["remoteCatalog": .bool(false)]
        let reply = AgentModelCatalogStore.reply(catalog: nil, delivery: nil, user: user)
        #expect(reply == ["catalog": .null, "delivery": .null, "user": user])
        #expect(AgentModelCatalogStore.remoteEnabled(user) == false)
        #expect(AgentModelCatalogStore.remoteEnabled(nil))
        #expect(AgentPageEvent.modelCatalog(reply).kind == "models.catalog")
        #expect(AgentModelCatalogStore.delivery("fetched") == "network")
        #expect(AgentModelCatalogStore.delivery("bundled") == "disk")
    }
}
