#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
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
}
#endif
