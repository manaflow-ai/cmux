#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// `debug.oracle.recorder` and `debug.oracle.turns` over a real action registry: arm,
/// perform, mark; the turn's facets equal the settled mark's, nested performs are one turn, `after`
/// reads only newer checkpoints, bad params are `invalid_params`, a refused request changes nothing,
/// and Release refuses both names `not_allowed`.
/// Run: `swift test --filter OracleRecorderControlTests`.
@MainActor @Suite(.serialized) struct OracleRecorderControlTests {
    @MainActor final class Model {
        var panes = 1
    }

    private struct Fixture {
        let model: Model
        let turns: OracleActionTurns
        let registry: ActionRegistry
        let router: ControlRouter
    }

    private func fixture(allowsDebug: Bool = true) -> Fixture {
        let model = Model()
        let facets = OracleFacets([
            OracleFacetSource(.topology, .mainActor { () throws(OracleFacetError) -> OracleValue in
                ["panes": OracleValue(model.panes)]
            }),
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in
                ["count": 0]
            }),
        ])
        let turns = OracleActionTurns()
        let registry = ActionRegistry(catalog: [], runTiming: NoActionRunTiming(), turnObserver: turns)
        registry.register(Action(id: "test.split", title: "Split") { model.panes += 1 })
        registry.register(Action(id: "test.twice", title: "Twice") { [weak registry] in
            _ = registry?.perform("test.split")
            _ = registry?.perform("test.split")
        })
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register(OracleControl(facets: facets).methods
                        + OracleRecorderControl(recorder: turns.recorder, facets: facets).methods)
        return Fixture(model: model, turns: turns, registry: registry, router: router)
    }

    private func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    private func failure(_ result: Result<JSONValue, ControlError>) -> ControlError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func aTurnCheckpointEqualsTheSettledMark() async throws {
        let fixture = fixture()
        let armed = try await call(fixture.router, OracleRecorderControl.recorder, ["arm": true, "facets": ["topology"]]).get()
        #expect(armed["armed"] == true)
        #expect(armed["checkpoint"]?["label"] == "armed")

        #expect(fixture.registry.perform("test.twice", invocation: ActionInvocation(origin: .cli)))
        #expect(fixture.model.panes == 3)
        let settled = try await call(fixture.router, OracleRecorderControl.recorder, ["mark": "settled"]).get()

        let turns = try await call(fixture.router, OracleRecorderControl.turns, ["after": 1]).get()
        let checkpoints = try #require(turns["checkpoints"]?.arrayValue)
        // The nested performs are part of the outer turn: one turn, then the mark.
        #expect(checkpoints.map { $0["label"] } == ["test.twice", "settled"])
        #expect(checkpoints[0]["origin"] == "cli")
        #expect(checkpoints[0]["ran"] == true)
        #expect(checkpoints[0]["facets"] == ["topology": ["panes": 3]])
        #expect(checkpoints[0]["facets"] == settled["checkpoint"]?["facets"])
        #expect(checkpoints[0]["facets"] != armed["checkpoint"]?["facets"])
        #expect(turns["count"] == 3)
    }

    @Test func clearAndDisarmStopRecording() async throws {
        let fixture = fixture()
        _ = try await call(fixture.router, OracleRecorderControl.recorder, ["arm": true, "facets": ["topology"]]).get()
        fixture.registry.perform("test.split")
        let cleared = try await call(fixture.router, OracleRecorderControl.recorder, ["clear": true, "arm": false]).get()
        #expect(cleared["armed"] == false)
        #expect(cleared["count"] == 0)
        #expect(cleared["nextSequence"] == 3)
        fixture.registry.perform("test.split")
        let turns = try await call(fixture.router, OracleRecorderControl.turns, [:]).get()
        #expect(turns["checkpoints"] == [])
    }

    @Test func badParamsAreInvalidParams() async {
        let fixture = fixture()
        let typo = await call(fixture.router, OracleRecorderControl.recorder, ["arm": true, "facets": ["topolgy"]])
        #expect(failure(typo)?.code == "invalid_params")
        let notAList = await call(fixture.router, OracleRecorderControl.recorder, ["arm": true, "facets": "topology"])
        #expect(failure(notAList)?.code == "invalid_params")
        let unarmedMark = await call(fixture.router, OracleRecorderControl.recorder, ["mark": "settled"])
        #expect(failure(unarmedMark)?.code == "invalid_params")
        let negative = await call(fixture.router, OracleRecorderControl.turns, ["after": -1])
        #expect(failure(negative)?.code == "invalid_params")
        let facetsWithoutArm = await call(fixture.router, OracleRecorderControl.recorder, ["facets": ["topolgy"]])
        #expect(failure(facetsWithoutArm)?.code == "invalid_params")
        let notABool = await call(fixture.router, OracleRecorderControl.recorder, ["clear": "yes"])
        #expect(failure(notABool)?.code == "invalid_params")
        // A refused arm leaves the recorder as it was.
        #expect(!fixture.turns.recorder.isArmed)
    }

    /// A refused request changes nothing, even when an earlier param would have: a clear with an arm
    /// of a background facet, and a mark in the request that disarms.
    @Test func aRefusedRequestChangesNothing() async throws {
        let fixture = fixture()
        _ = try await call(fixture.router, OracleRecorderControl.recorder, ["arm": true, "facets": ["topology"]]).get()
        fixture.registry.perform("test.split")
        let before = try await call(fixture.router, OracleRecorderControl.turns, [:]).get()
        #expect(before["count"] == 2)

        let background = await call(fixture.router, OracleRecorderControl.recorder,
                                    ["clear": true, "arm": true, "facets": ["terminals"]])
        #expect(failure(background)?.code == "invalid_params")
        #expect(try await call(fixture.router, OracleRecorderControl.turns, [:]).get() == before)

        let markWhileDisarming = await call(fixture.router, OracleRecorderControl.recorder,
                                            ["clear": true, "arm": false, "mark": "settled"])
        #expect(failure(markWhileDisarming)?.code == "invalid_params")
        #expect(try await call(fixture.router, OracleRecorderControl.turns, [:]).get() == before)
        #expect(fixture.turns.recorder.isArmed)
        #expect(fixture.turns.recorder.armedFacets == [.topology])
    }

    @Test func aReleaseRouterRefusesTheRecorder() async {
        let fixture = fixture(allowsDebug: false)
        for method in [OracleRecorderControl.recorder, OracleRecorderControl.turns] {
            #expect(fixture.router.method(named: method) == nil)
            let result = await call(fixture.router, method, [:])
            #expect(failure(result)?.code == "not_allowed")
        }
    }
}
#endif
