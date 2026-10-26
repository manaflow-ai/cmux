#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
import CmuxNextOracle
import CmuxNextSettings
import Observation
import Testing

/// A model a wait_for facet reads, so a change reaches the wait through Observation alone.
@MainActor @Observable final class OracleWaitModel {
    var count = 0
}

/// The calls a settle made, in order (the stages run one after the other).
@MainActor final class OracleSettleLog {
    var stages: [String] = []
}

/// `debug.oracle.settle` and `debug.oracle.wait_for` (p15-oracle-031): the settle passes its stages in order
/// and answers settled; a stage that misses `settleMaxMs` answers the pending list with what still keeps the
/// app from settling (a forced pending intent among it); `wait_for` resolves on the facet's own change
/// signal and answers `pending` when `maxMs` passes first. Run: `swift test --filter OracleSettleControlTests`.
@MainActor @Suite(.serialized) struct OracleSettleControlTests {
    private func router(facets: OracleFacets = OracleFacets([]), sources: OracleSettleSources,
                        allowsDebug: Bool = true) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register(OracleSettleControl(router: router, facets: facets, sources: sources).methods)
        router.snapshots.publish { snapshot in
            snapshot.topology.isLoaded = true
            snapshot.topology.daemonSequence = 7
        }
        return router
    }

    private func idle(_ log: OracleSettleLog? = nil, daemon: (@MainActor @Sendable (UInt64) async -> [String])? = nil,
                      pending: @escaping @MainActor @Sendable () -> [String] = { [] }) -> OracleSettleSources {
        OracleSettleSources(
            daemon: daemon ?? { _ in
                log?.stages.append("daemon")
                return []
            },
            motionIdle: { _ in
                log?.stages.append("motion")
                return true
            },
            commit: { log?.stages.append("commit") },
            pending: pending)
    }

    private func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    private func failure(_ result: Result<JSONValue, ControlError>) -> ControlError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: - settle

    @Test func aSettleRunsEveryStageInOrderAndAnswersSettled() async throws {
        let log = OracleSettleLog()
        let router = router(sources: idle(log))
        let reply = try await call(router, OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 2_000]).get()
        #expect(reply["settled"] == true)
        #expect(reply["pending"] == [])
        #expect(reply["sequence"] == 7)
        #expect(log.stages == ["daemon", "motion", "commit"])
    }

    @Test func aForcedPendingIntentAppearsInPending() async throws {
        // The daemon half never finishes (an intent nobody settles) until the deadline cancels it.
        let (never, keep) = AsyncStream<Void>.makeStream()
        let sources = idle(daemon: { _ in
            for await _ in never {}
            keep.finish()
            return []
        }, pending: { ["intent:renameTab"] })
        let reply = try await call(router(sources: sources), OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 50]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["daemon", "intent:renameTab"])
    }

    @Test func theDaemonsOwnPendingWaitsEndTheSettle() async throws {
        let log = OracleSettleLog()
        let sources = idle(log, daemon: { _ in ["daemon.connection"] })
        let reply = try await call(router(sources: sources), OracleSettleControl.settle, ["sequence": 7]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["daemon.connection"])
        #expect(log.stages.isEmpty)
    }

    @Test func aSnapshotBehindTheSequenceIsPending() async throws {
        let log = OracleSettleLog()
        let reply = try await call(router(sources: idle(log)), OracleSettleControl.settle, ["sequence": 9, "settleMaxMs": 50]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["control.snapshot"])
        #expect(log.stages.isEmpty)
    }

    @Test func badSettleParamsAreInvalidParams() async {
        let router = router(sources: idle())
        #expect(failure(await call(router, OracleSettleControl.settle, ["settleMaxMs": 0]))?.code == "invalid_params")
        #expect(failure(await call(router, OracleSettleControl.settle, ["settleMaxMs": 60_001]))?.code == "invalid_params")
        #expect(failure(await call(router, OracleSettleControl.settle, ["sequence": "soon"]))?.code == "invalid_params")
    }

    // MARK: - wait_for

    @Test func aConditionThatHoldsAnswersAtTheFirstRead() async throws {
        let facets = OracleFacets([
            OracleFacetSource(.windows, .mainActor { () throws(OracleFacetError) -> OracleValue in ["count": 1] }),
        ])
        let reply = try await call(router(facets: facets, sources: idle()), OracleSettleControl.waitFor,
                                   ["pointer": "/windows/count", "equals": 1, "maxMs": 1_000]).get()
        #expect(reply["satisfied"] == true)
        #expect(reply["value"] == 1)
        #expect(reply["evaluations"] == 1)
    }

    @Test func aWaitResolvesOnTheFacetsObservedChange() async throws {
        let model = OracleWaitModel()
        let (reads, read) = AsyncStream<Int>.makeStream()
        let facets = OracleFacets([
            OracleFacetSource(.windows, .mainActor { () throws(OracleFacetError) -> OracleValue in
                read.yield(model.count)
                return ["count": OracleValue(model.count)]
            }),
        ])
        let router = router(facets: facets, sources: idle())
        let waiting = Task { await call(router, OracleSettleControl.waitFor, ["pointer": "/windows/count", "predicate": ["op": "gte", "value": 3], "maxMs": 10_000]) }
        // The first read found 0; only the model change (no publish) wakes the wait.
        for await count in reads {
            #expect(count == 0)
            break
        }
        model.count = 3
        let reply = try await waiting.value.get()
        #expect(reply["satisfied"] == true)
        #expect(reply["value"] == 3)
        #expect(reply["evaluations"] == 2)
    }

    @Test func aWaitPastMaxMsAnswersPending() async throws {
        let facets = OracleFacets([
            OracleFacetSource(.windows, .mainActor { () throws(OracleFacetError) -> OracleValue in ["count": 0] }),
        ])
        let reply = try await call(router(facets: facets, sources: idle()), OracleSettleControl.waitFor,
                                   ["pointer": "/windows/count", "equals": 1, "maxMs": 30]).get()
        #expect(reply["satisfied"] == false)
        #expect(reply["pending"] == ["/windows/count"])
        #expect(reply["value"] == 0)
    }

    @Test func aFacetWithoutAProviderIsUnavailableAndABadPointerInvalid() async {
        let router = router(sources: idle())
        let missing = await call(router, OracleSettleControl.waitFor, ["pointer": "/focus/window", "predicate": "exists", "maxMs": 10])
        #expect(failure(missing)?.code == "unavailable")
        #expect(failure(missing)?.data?["task"] == "p15-oracle-034")
        let daemon = await call(router, OracleSettleControl.waitFor, ["pointer": "/daemon/x", "predicate": "exists", "maxMs": 10])
        #expect(failure(daemon)?.code == "invalid_params")
        let both = await call(router, OracleSettleControl.waitFor, ["pointer": "/focus", "equals": 1, "predicate": "exists", "maxMs": 10])
        #expect(failure(both)?.data?["param"] == "predicate")
    }

    @Test func aReleaseRouterRefusesBoth() async {
        let router = router(sources: idle(), allowsDebug: false)
        #expect(router.method(named: OracleSettleControl.settle) == nil)
        #expect(router.method(named: OracleSettleControl.waitFor) == nil)
        // The oracle family answers not_allowed in Release (p15-oracle-030), so the runner can tell it from an older build.
        #expect(failure(await call(router, OracleSettleControl.settle, [:]))?.code == "not_allowed")
        #expect(failure(await call(router, OracleSettleControl.waitFor, [:]))?.code == "not_allowed")
    }

    // MARK: - the condition

    @Test func pointersUnescapeAndIndexArrays() throws {
        let condition = try OracleWaitCondition(params: ["pointer": "/tabs/a~1b/~0c/1", "predicate": "exists", "maxMs": 5])
        #expect(condition.facet == .tabs)
        #expect(condition.path == ["a/b", "~c", "1"])
        #expect(condition.limit == .milliseconds(5))
        let value: JSONValue = ["a/b": ["~c": ["x", "y"]]]
        #expect(condition.value(in: value) == "y")
        #expect(throws: OracleWaitConditionError.self) { try OracleWaitCondition(params: ["pointer": "/tabs/~2", "predicate": "exists", "maxMs": 5]) }
        #expect(throws: OracleWaitConditionError.maxMs) { try OracleWaitCondition(params: ["pointer": "/tabs", "predicate": "exists", "maxMs": 30_001]) }
    }

    @Test func predicatesFollowTheCaseSchema() throws {
        func holds(_ predicate: JSONValue, _ value: JSONValue?, baseline: JSONValue? = nil) throws -> Bool {
            try OracleWaitCondition(params: ["pointer": "/tabs", "predicate": predicate, "maxMs": 5]).holds(value, baseline: baseline)
        }
        #expect(try holds("exists", .null))
        #expect(try holds("absent", JSONValue?.none))
        #expect(try holds("empty", []))
        #expect(try !holds("nonEmpty", ""))
        #expect(try holds("changed", 2, baseline: 1))
        #expect(try !holds("changed", 1, baseline: 1))
        // Facets carry decimals as strings: a numeric string compares as its number.
        #expect(try holds(["op": "gt", "value": 0.5], "0.75"))
        #expect(try holds(["op": "contains", "value": "b"], ["a", "b"]))
        #expect(try holds(["op": "lengthEquals", "value": 2], ["k": 1, "l": 2]))
        #expect(throws: OracleWaitConditionError.test) { try holds(["op": "near", "value": 1], 1) }
    }
}
#endif
