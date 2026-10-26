#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// The app's oracle facet list (p15-oracle-030): AppServices builds it with at most one provider per
/// facet, and `debug.oracle.snapshot` over it lists every facet and answers each facet that has no
/// provider yet as not-comparable with its task. Run: `swift test --filter AppOracleHostTests`.
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

    /// p15-oracle-032: the registry's perform-turn observer is the app's one turn recorder, and the
    /// `debug.oracle.*` methods AppControl registers read that same recorder, so a turn of the app's
    /// registry shows in `debug.oracle.turns`.
    @Test func theAppRegistryReportsItsTurnsToTheRecorderTheRouterReads() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.registry.turnObserver === services.oracleTurns)

        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        router.register(services.oracleControlMethods())
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
}
#endif
