#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextDaemon
import CmuxNextOracle
import Testing

/// The oracle's `intents` facet: pending intents with their transaction, case and target's
/// public id; a refused command (the daemon error of the fleet case) gives one rolledBack delta and names its
/// case; a refused turn (an action that did not run, a handler that refused) gives one refused delta and names
/// the action; a refusal outside a turn counts nothing; reading the facet changes no state, and the turn
/// recorder can arm it, so I3 can compare a turn checkpoint with the settled one.
/// Run: `swift test --filter OracleIntentsFacetTests`.
@MainActor @Suite(.serialized) struct OracleIntentsFacetTests {
    nonisolated private static let pane = PaneID(rawValue: 10)
    nonisolated private static let paneResource = "pane_" + String(repeating: "a", count: 32)

    private struct Fixture {
        let store: DaemonStore
        let turns: OracleActionTurns
        let registry: ActionRegistry
        let facets: OracleFacets
    }

    /// The store, turn observer and registry, with a copy of the App's wiring (AppActionContext.observeRefusals):
    /// these tests cover OracleActionTurns and the facet; AppOracleHostTests'
    /// `aHandlerRefusalCountsThroughTheAppRefusalWiring` covers the App's own wiring.
    private func fixture() -> Fixture {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [
                ScreenSnapshot(id: 100, name: "first", active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                               panes: [PaneSnapshot(id: Self.pane, resourceID: ResourceID(rawValue: Self.paneResource),
                                                    name: "old", tabs: [TabSnapshot(surface: 1)])]),
            ]),
        ]))
        let turns = OracleActionTurns()
        let registry = ActionRegistry(catalog: [], runTiming: NoActionRunTiming(), turnObserver: turns)
        registry.willRunObservers.append { _, _ in turns.runStarted() }
        registry.refusalObserver = { _, _ in turns.noteRefusal() }
        registry.register(Action(id: "test.run", title: "Run") {})
        registry.register(Action(id: "test.disabled", title: "Disabled", isEnabled: { false }) {})
        registry.register(Action(id: "test.refuse", title: "Refuse") { [weak registry] in registry?.refuse("no target") })
        registry.register(Action(id: "test.outer", title: "Outer") { [weak registry] in _ = registry?.perform("test.refuse") })
        return Fixture(store: store, turns: turns, registry: registry,
                       facets: OracleFacets([OracleIntentsFacet(store: store, turns: turns)]))
    }

    private func read(_ fixture: Fixture) throws -> OracleValue {
        let capture = try fixture.facets.beginCapture([.intents])
        return try #require(capture.completed?["intents"])
    }

    private func total(_ value: OracleValue, _ name: String) throws -> Double {
        guard case .number(let number)? = value["totals"]?[name] else { throw Missing(total: name) }
        return number
    }

    /// The runner diffs the monotonic totals of two checkpoints.
    private func delta(_ before: OracleValue, _ after: OracleValue, _ name: String) throws -> Double {
        try total(after, name) - total(before, name)
    }

    private struct Missing: Error {
        let total: String
    }

    @Test func aPendingIntentShowsItsTransactionCaseAndTarget() throws {
        let fixture = fixture()
        let transaction = ClientTransactionID.generate()
        fixture.store.intend(.renamePane(pane: Self.pane, name: "secret name"), transaction: transaction)
        let value = try read(fixture)
        let expected: OracleValue = [["intent": .string(transaction.rawValue), "op": "renamePane", "target": .string(Self.paneResource)]]
        #expect(value["pending"] == expected)
    }

    /// The fleet case's daemon error, as the store sees it: the command failed and the store took the rename back.
    @Test func aRefusedCommandGivesOneRollbackDeltaAndItsCase() throws {
        let fixture = fixture()
        let before = try read(fixture)
        let transaction = ClientTransactionID.generate()
        fixture.store.intend(.renamePane(pane: Self.pane, name: "logs"), transaction: transaction)
        fixture.store.rejectIntent(transaction)
        let after = try read(fixture)
        #expect(try delta(before, after, "rolledBack") == 1)
        #expect(try delta(before, after, "applied") == 0)
        #expect(after["lastRefusal"]?["intent"] == "renamePane")
        #expect(after["pending"] == [])
    }

    @Test func aRefusedTurnGivesOneRefusedDeltaAndItsAction() throws {
        let fixture = fixture()
        let before = try read(fixture)
        #expect(!fixture.registry.perform("test.disabled"))
        let disabled = try read(fixture)
        #expect(try delta(before, disabled, "refused") == 1)
        #expect(disabled["lastRefusal"]?["action"] == "test.disabled")

        fixture.registry.perform("test.refuse")
        let refused = try read(fixture)
        #expect(try delta(disabled, refused, "refused") == 1)
        #expect(refused["lastRefusal"]?["action"] == "test.refuse")

        // A handler that runs a refused action: one refusal, named after the action that was run.
        fixture.registry.perform("test.outer")
        let outer = try read(fixture)
        #expect(try delta(refused, outer, "refused") == 1)
        #expect(outer["lastRefusal"]?["action"] == "test.outer")
    }

    @Test func aRunThatRefusesNothingOrARefusalOutsideATurnCountsNothing() throws {
        let fixture = fixture()
        let before = try read(fixture)
        fixture.registry.perform("test.run")
        fixture.registry.refuse("a gesture outside any action run")
        fixture.registry.perform("test.run")
        let after = try read(fixture)
        #expect(try delta(before, after, "refused") == 0)
        #expect(after["lastRefusal"]?["action"] == OracleValue.null)
    }

    /// Acceptance: reading the facet changes no state, and the turn recorder arms it (a main-actor facet), so a
    /// turn checkpoint and the settled mark hold it for I3.
    @Test func readingChangesNothingAndTheRecorderArmsIt() throws {
        let fixture = fixture()
        fixture.store.intend(.renamePane(pane: Self.pane, name: "logs"), transaction: .generate())
        let totals = fixture.store.intentTotals
        let first = try read(fixture)
        let second = try read(fixture)
        #expect(first == second)
        #expect(fixture.store.intentTotals == totals)
        #expect(fixture.store.pendingIntents.count == 1)
        try fixture.turns.recorder.arm(fixture.facets, requested: [.intents])
        fixture.registry.perform("test.disabled")
        let turn = try #require(fixture.turns.recorder.ring.checkpoints(after: nil, last: 1).last)
        #expect(turn.value["facets"]?["intents"]?["totals"]?["refused"] == 1)
    }
}
#endif
