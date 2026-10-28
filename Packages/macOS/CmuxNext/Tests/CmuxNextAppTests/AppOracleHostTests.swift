#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// The app's oracle facet list: AppServices builds it with at most one provider per
/// facet, and `debug.oracle.snapshot` over it lists every facet and answers each facet that has no
/// provider yet as not-comparable with its task; the invariants facet is the desync check.
/// Run: `swift test --filter AppOracleHostTests`.
@MainActor @Suite(.serialized) struct AppOracleHostTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    @Test func theAppListServesEveryFacet() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.duplicates.isEmpty)
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        router.register(OracleControl(host: services).methods)

        let list = try await router.handle(ControlRequest(id: "1", method: OracleControl.snapshot, params: ["list": true])).get()
        let expected: [JSONValue] = OracleFacet.allCases.map { facet -> JSONValue in
            ["facet": .string(facet.rawValue), "provided": .bool(facets.provided.contains(facet)), "task": .string(facet.task)]
        }
        #expect(list == .array(expected))

        let missing = OracleFacet.allCases.filter { !facets.provided.contains($0) }
        let params: [String: JSONValue] = ["facets": .array(missing.map { .string($0.rawValue) })]
        let reply = try await router.handle(ControlRequest(id: "2", method: OracleControl.snapshot, params: params)).get()
        let answers: [String: JSONValue] = Dictionary(uniqueKeysWithValues: missing.map { facet in
            (facet.rawValue, ["status": "not-comparable", "reason": .string("no provider for \(facet.rawValue) in this build"),
                              "task": .string(facet.task)] as JSONValue)
        })
        #expect(reply == .object(answers))
    }

    /// The invariants facet runs the check `debug.desync` runs, in the snapshot's turn.
    @Test func theInvariantsFacetRunsTheDesyncCheck() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.input.start(services: services)  // the app's launch post; init only wires it
        let monitor = try #require(services.input.monitor)
        let before = monitor.checks
        let snapshot = try #require(try services.makeOracleFacets().beginCapture([.invariants]).completed)
        let invariants = try #require(snapshot["invariants"])
        #expect(invariants["checks"] == OracleValue(before + 1))
        let ids = (monitor.lastResult?.violations ?? []).map { OracleValue.string($0.invariant.rawValue) }
        #expect(invariants["violations"] == .array(ids))
        #expect(invariants["windowInvariants"] == .array(WindowInvariants.problems(services.windows).map(OracleValue.string)))
    }

    /// The registry's perform-turn observer is the app's one turn recorder, and the
    /// `debug.oracle.*` methods AppControl registers read that same recorder, so a turn of the app's
    /// registry shows in `debug.oracle.turns`.
    @Test func theAppRegistryReportsItsTurnsToTheRecorderTheRouterReads() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.registry.turnObserver === services.oracleTurns)

        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        router.register(services.oracleControlMethods(snapshots: router.snapshots))
        let armed = try await router.handle(ControlRequest(id: "1", method: OracleRecorderControl.recorder,
                                                           params: ["arm": true, "facets": ["topology"]])).get()
        let after = try #require(armed["checkpoint"]?["sequence"]?.intValue)

        services.registry.register(Action(id: "test.oracle.turn", title: "Turn") {})
        #expect(services.registry.perform("test.oracle.turn", invocation: ActionInvocation(origin: .cli)))

        let turns = try await router.handle(ControlRequest(id: "2", method: OracleRecorderControl.turns,
                                                           params: ["after": .number(Double(after))])).get()
        let checkpoints = try #require(turns["checkpoints"]?.arrayValue)
        #expect(checkpoints.map { $0["label"] } == ["test.oracle.turn"])
        #expect(checkpoints.first?["kind"] == "turn")
        #expect(checkpoints.first?["origin"] == "cli")
    }

    /// The app list's intents facet reads the app's daemon store and counts a refused turn of the
    /// app's registry, by the action's id.
    @Test func theIntentsFacetCountsARefusedTurnOfTheAppRegistry() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.intents))
        let before = try #require(try facets.beginCapture([.intents]).completed?["intents"])
        services.registry.register(Action(id: "test.oracle.refused", title: "Refused", isEnabled: { false }) {})
        #expect(!services.registry.perform("test.oracle.refused", invocation: ActionInvocation(origin: .cli)))
        let after = try #require(try facets.beginCapture([.intents]).completed?["intents"])
        guard case .number(let refusedBefore)? = before["totals"]?["refused"],
              case .number(let refusedAfter)? = after["totals"]?["refused"] else {
            Issue.record("the intents facet has no refused total")
            return
        }
        #expect(refusedAfter - refusedBefore == 1)
        #expect(after["lastRefusal"]?["action"] == "test.oracle.refused")
        #expect(services.daemon.store.pendingIntents.isEmpty)
        #expect(after["pending"] == .array([]))
    }

    /// The App's own refusal wiring (AppActions.bind installs AppActionContext.observeRefusals,
    /// which feeds the turn observer the registry's willRun and refusal observers) counts a handler that refuses,
    /// the normal refusal (no target, unavailable), as one refused turn named by its action. The disabled action
    /// above takes the `!ran` path, which counts with no wiring; this one counts only through it.
    @Test func aHandlerRefusalCountsThroughTheAppRefusalWiring() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let registry = services.registry
        registry.register(Action(id: "test.oracle.handlerRefused", title: "Handler refused") { [weak registry] in
            registry?.refuse("no target")
        })
        let facets = services.makeOracleFacets()
        let before = try #require(try facets.beginCapture([.intents]).completed?["intents"])
        // As the control socket runs it: the caller gets the reason, so no HUD shows.
        let reason = registry.capturingRefusal { _ = registry.perform("test.oracle.handlerRefused", invocation: ActionInvocation(origin: .cli)) }
        #expect(reason == "no target")
        let after = try #require(try facets.beginCapture([.intents]).completed?["intents"])
        guard case .number(let refusedBefore)? = before["totals"]?["refused"],
              case .number(let refusedAfter)? = after["totals"]?["refused"] else {
            Issue.record("the intents facet has no refused total")
            return
        }
        #expect(refusedAfter - refusedBefore == 1)
        #expect(after["lastRefusal"]?["action"] == "test.oracle.handlerRefused")
    }
}
#endif
