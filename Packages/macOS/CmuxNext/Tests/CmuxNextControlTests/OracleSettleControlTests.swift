#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextOracle
import CmuxNextSettings
import Observation
import Testing

/// The control wire's JSON (CmuxNextDaemon has its own `JSONValue`, which the testable import also brings in).
private typealias JSONValue = CmuxNextSettings.JSONValue

/// A model a wait_for facet reads, so a change reaches the wait through Observation alone.
@MainActor @Observable final class OracleWaitModel {
    var count = 0
}

/// State owned off the main actor with its own change point, as a background facet's owner has: `set` signals
/// its one subscriber; nothing publishes a control snapshot.
actor OracleBackgroundModel {
    private(set) var count = 0
    nonisolated let changes: AsyncStream<Void>
    private let changed: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        changes = stream
        changed = continuation
    }

    func set(_ count: Int) {
        self.count = count
        changed.yield()
    }
}

/// The calls a settle made, in order (the stages run one after the other).
@MainActor final class OracleSettleLog {
    var stages: [String] = []
    var syncs = 0
    var connectionChanges: [Int] = []
}

/// `debug.oracle.settle` and `debug.oracle.wait_for`: the settle passes its stages in order
/// and answers settled; a stage that misses `settleMaxMs` answers the pending list with what still keeps the
/// app from settling (a real store's forced pending intent among it); a sync barrier that cannot answer waits for
/// the next connection instead of failing; `wait_for` resolves on the facet's own change signal and answers
/// `pending` when `maxMs` passes first. Run: `swift test --filter OracleSettleControlTests`.
@MainActor @Suite(.serialized) struct OracleSettleControlTests {
    private static let key = WorkspaceKey(rawValue: "w1")

    private func router(facets: OracleFacets = OracleFacets([]), sources: OracleSettleSources,
                        allowsDebug: Bool = true, daemonSequence: UInt64 = 7) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register(OracleSettleControl(router: router, facets: facets, sources: sources).methods)
        router.snapshots.publish { snapshot in
            snapshot.topology.isLoaded = true
            snapshot.topology.daemonSequence = daemonSequence
        }
        return router
    }

    private func idle(_ log: OracleSettleLog? = nil, sync: (@MainActor @Sendable () async -> OracleSyncAttempt)? = nil,
                      daemon: (@MainActor @Sendable (OracleDaemonMark) async -> [String])? = nil) -> OracleSettleSources {
        OracleSettleSources(
            sync: sync ?? {
                log?.syncs += 1
                return .reached(OracleDaemonMark(sequence: 7, epoch: 1))
            },
            connectionChange: { epoch in
                log?.connectionChanges.append(epoch)
                return true
            },
            epoch: { 1 },
            daemon: daemon ?? { _ in
                log?.stages.append("daemon")
                return []
            },
            motionIdle: {
                log?.stages.append("motion")
                return true
            },
            commit: { log?.stages.append("commit") },
            pending: { [] })
    }

    /// A real store holding workspace `w1`, its applied sequence at `applied`.
    private static func store(applied: UInt64) -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1,
                                         workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "one")]))
        store.advanceAppliedSequence(to: applied)
        return store
    }

    /// The production daemon-store sources (``OracleSettleSources/init(store:sync:motionIdle:commit:motion:)``) with an
    /// idle motion and commit.
    private static func storeSources(_ store: DaemonStore, sync: @escaping @MainActor @Sendable () async -> OracleSyncAttempt = {
        .unavailable(epoch: 0)
    }) -> OracleSettleSources {
        OracleSettleSources(store: store, sync: sync, motionIdle: { true }, commit: {}, motion: { [] })
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
        #expect(log.syncs == 0, "an explicit sequence ran the sync barrier")
    }

    /// A settle right after a `kill` or `restart` step: the daemon cannot answer the sync, so the settle waits for
    /// the next connection and syncs again, within `settleMaxMs`, instead of failing at once.
    @Test func aSyncThatIsUnavailableWaitsForTheNextConnection() async throws {
        let log = OracleSettleLog()
        let sources = idle(log, sync: {
            log.syncs += 1
            return log.syncs == 1 ? .unavailable(epoch: 3) : .reached(OracleDaemonMark(sequence: 7, epoch: 4))
        })
        let reply = try await call(router(sources: sources), OracleSettleControl.settle, ["settleMaxMs": 2_000]).get()
        #expect(reply["settled"] == true)
        #expect(reply["sequence"] == 7)
        #expect(log.syncs == 2)
        #expect(log.connectionChanges == [3], "the retry did not wait for the connection after the unusable one")
        #expect(log.stages == ["daemon", "motion", "commit"])
    }

    @Test func aDaemonThatNeverComesBackIsTheSyncStage() async throws {
        let store = Self.store(applied: 0)
        let reply = try await call(router(sources: Self.storeSources(store)), OracleSettleControl.settle, ["settleMaxMs": 50]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["control.sync"])
        #expect(reply["sequence"] == nil)
        for _ in 0..<1_000 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0, "the deadline left the connection wait parked")
    }

    /// The sync mark's connection went away before the store applied it: the settle syncs again on the next one.
    @Test func aSyncMarkWhoseConnectionChangedSyncsAgain() async throws {
        let log = OracleSettleLog()
        let sources = idle(log, sync: {
            log.syncs += 1
            return .reached(OracleDaemonMark(sequence: 7, epoch: log.syncs))
        }, daemon: { mark in
            log.stages.append("daemon@\(mark.epoch)")
            return mark.epoch == 1 ? [DaemonSettleWait.connection.rawValue] : []
        })
        let reply = try await call(router(sources: sources), OracleSettleControl.settle, ["settleMaxMs": 2_000]).get()
        #expect(reply["settled"] == true)
        #expect(log.stages == ["daemon@1", "daemon@2", "motion", "commit"])
    }

    /// An explicit sequence belongs to the connection of the turn the request was accepted in: a change of
    /// connection since then cannot be reached and names the connection.
    @Test func anExplicitSequenceOnAChangedConnectionNamesTheConnection() async throws {
        let store = Self.store(applied: 9)
        let sources = OracleSettleSources(store: store, sync: { .unavailable(epoch: 0) }, motionIdle: { true }, commit: {}, motion: { [] })
        let changed = OracleSettleSources(sync: sources.sync, connectionChange: sources.connectionChange, epoch: sources.epoch,
                                          daemon: { mark in
                                              store.apply(.disconnected(reason: "restart"))
                                              return await sources.daemon(mark)
                                          },
                                          motionIdle: sources.motionIdle, commit: sources.commit, pending: sources.pending)
        let reply = try await call(router(sources: changed), OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 2_000]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["daemon.connection"])
    }

    /// The acceptance case on a real store: an intent nobody echoes keeps the daemon stage open past the
    /// deadline, and the pending list names the store's own wait and the intent's case (never its payload).
    @Test func aForcedPendingIntentAppearsInPending() async throws {
        let store = Self.store(applied: 7)
        store.intend(.renameWorkspace(key: Self.key, name: "private name"), transaction: .generate())
        let reply = try await call(router(sources: Self.storeSources(store)), OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 50]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["daemon.intents", "intent:renameWorkspace"])
        for _ in 0..<1_000 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0, "the deadline left the idle wait parked")
    }

    /// A sequence the store never applies is told apart from a pending intent: the store's own answer to the
    /// deadline's cancel reaches the list.
    @Test func anUnappliedSequenceIsDaemonApplied() async throws {
        let store = Self.store(applied: 3)
        let reply = try await call(router(sources: Self.storeSources(store)), OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 50]).get()
        #expect(reply["settled"] == false)
        #expect(reply["pending"] == ["daemon.applied"])
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

    /// `Slow` multiplies the case's `settleMaxMs` (at most 60,000) by 5.
    @Test func aSlowBoundIsAccepted() async throws {
        let reply = try await call(router(sources: idle()), OracleSettleControl.settle, ["sequence": 7, "settleMaxMs": 75_000]).get()
        #expect(reply["settled"] == true)
        #expect(try OracleSettleControl.settleBound(["settleMaxMs": 300_000]) == .milliseconds(300_000))
    }

    @Test func badSettleParamsAreInvalidParams() async {
        let router = router(sources: idle())
        #expect(failure(await call(router, OracleSettleControl.settle, ["settleMaxMs": 0]))?.code == "invalid_params")
        #expect(failure(await call(router, OracleSettleControl.settle, ["settleMaxMs": 300_001]))?.code == "invalid_params")
        #expect(failure(await call(router, OracleSettleControl.settle, ["settleMaxMs": 1.5]))?.code == "invalid_params")
        #expect(failure(await call(router, OracleSettleControl.settle, ["sequence": "soon"]))?.code == "invalid_params")
    }

    @Test func pendingNamesTheIntentCaseAndTheMotionTrace() {
        let names = OracleSettleSources.pending(intents: [.renameWorkspace(key: Self.key, name: "secret"), .closeTabs(surfaces: [])],
                                                motion: ["tabs.slide"])
        #expect(names == ["intent:renameWorkspace", "intent:closeTabs", "motion:tabs.slide"])
    }

    /// The test phase's 1,000 settles, each parked on the real store until its sequence is applied: every one
    /// settles, and the p99 of the reply's `elapsed_ms` is below `settleMaxMs`. The fleet runs the same count over
    /// the socket against a DEV build: `scripts/cmux-next/bench-oracle-settle.py`.
    @Test func aThousandSettlesHaveAP99BelowSettleMaxMs() async throws {
        let store = Self.store(applied: 0)
        let router = router(sources: Self.storeSources(store), daemonSequence: 1_000)
        let settleMaxMs = 2_000
        var elapsed: [Double] = []
        for sequence in 1...1_000 {
            let settling = Task { await call(router, OracleSettleControl.settle, ["sequence": JSONValue(sequence), "settleMaxMs": JSONValue(settleMaxMs)]) }
            for _ in 0..<10_000 where store.pendingWaitCount == 0 { await Task.yield() }
            store.advanceAppliedSequence(to: UInt64(sequence))
            let reply = try await settling.value.get()
            #expect(reply["settled"] == true, "settle \(sequence): \(reply)")
            elapsed.append(reply["elapsed_ms"]?.doubleValue ?? .infinity)
        }
        elapsed.sort()
        let p99 = elapsed[Int(Double(elapsed.count) * 0.99) - 1]
        #expect(p99 < Double(settleMaxMs), "p99 \(p99) ms, max \(elapsed.last ?? 0) ms")
        #expect(store.pendingWaitCount == 0)
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

    /// An off-main facet (terminals, daemon vt-state) changes without a snapshot publish: its provider's own change
    /// signal wakes the wait.
    @Test func aWaitResolvesOnABackgroundFacetsChangeSignal() async throws {
        let model = OracleBackgroundModel()
        let (reads, read) = AsyncStream<Int>.makeStream()
        let facets = OracleFacets([
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in
                let count = await model.count
                read.yield(count)
                return ["lines": OracleValue(count)]
            }, changes: { model.changes }),
        ])
        let router = router(facets: facets, sources: idle())
        let waiting = Task { await call(router, OracleSettleControl.waitFor, ["pointer": "/terminals/lines", "equals": 2, "maxMs": 10_000]) }
        for await count in reads {
            #expect(count == 0)
            break
        }
        await model.set(2)
        let reply = try await waiting.value.get()
        #expect(reply["satisfied"] == true)
        #expect(reply["value"] == 2)
    }

    /// The terminals facet (a split facet): its screen changes off the main actor with no publish and no
    /// mirror change; the host's change signal wakes a wait on `/terminals/list/0/last24Sha256`.
    @Test func aWaitOnTheTerminalsScreenResolvesOnItsChangeSignal() async throws {
        let model = OracleBackgroundModel()
        let (reads, read) = AsyncStream<Int>.makeStream()
        let facet = OracleTerminalsFacet(rewrite: .init(root: [], home: []), hash: { "hashed(\($0))" }, changes: { model.changes }) {
            [OracleTerminalsFacet.Terminal(terminal: "term_a", tab: nil, cols: 80, rows: 24, title: "", cwd: nil, ended: false, exitCode: nil,
                                           attach: nil, screen: {
                                               let count = await model.count
                                               read.yield(count)
                                               return "count \(count)"
                                           })]
        }
        let router = router(facets: OracleFacets([facet]), sources: idle())
        let waiting = Task {
            await call(router, OracleSettleControl.waitFor,
                       ["pointer": "/terminals/list/0/last24Sha256", "equals": "hashed(count 2)", "maxMs": 10_000])
        }
        for await count in reads {
            #expect(count == 0)
            break
        }
        await model.set(2)
        let reply = try await waiting.value.get()
        #expect(reply["satisfied"] == true)
        #expect(reply["value"] == "hashed(count 2)")
    }

    @Test func aBackgroundFacetWithoutAChangeSignalIsUnavailable() async {
        let facets = OracleFacets([
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in ["lines": 0] }),
        ])
        let reply = await call(router(facets: facets, sources: idle()), OracleSettleControl.waitFor,
                               ["pointer": "/terminals/lines", "equals": 2, "maxMs": 10])
        #expect(failure(reply)?.code == "unavailable")
        #expect(failure(reply)?.data?["reason"] == "no_change_signal")
    }

    /// The action applied its intent in the input's turn, before the runner asked: `changed` compares with the
    /// runner's `since` (the value at the `before` checkpoint), so the wait holds at its first read.
    @Test func changedComparesWithTheValueBeforeTheStep() async throws {
        let model = OracleWaitModel()
        let facets = OracleFacets([
            OracleFacetSource(.windows, .mainActor { () throws(OracleFacetError) -> OracleValue in ["count": OracleValue(model.count)] }),
        ])
        model.count = 3
        let reply = try await call(router(facets: facets, sources: idle()), OracleSettleControl.waitFor,
                                   ["pointer": "/windows/count", "predicate": "changed", "since": 0, "maxMs": 1_000]).get()
        #expect(reply["satisfied"] == true)
        #expect(reply["evaluations"] == 1)
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
        let noSince = await call(router, OracleSettleControl.waitFor, ["pointer": "/focus", "predicate": "changed", "maxMs": 10])
        #expect(failure(noSince)?.data?["param"] == "since")
    }

    @Test func aReleaseRouterRefusesBoth() async {
        let router = router(sources: idle(), allowsDebug: false)
        #expect(router.method(named: OracleSettleControl.settle) == nil)
        #expect(router.method(named: OracleSettleControl.waitFor) == nil)
        // The oracle family answers not_allowed in Release, so the runner can tell it from an older build.
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
        func holds(_ predicate: JSONValue, _ value: JSONValue?, since: JSONValue? = nil) throws -> Bool {
            var params: [String: JSONValue] = ["pointer": "/tabs", "predicate": predicate, "maxMs": 5]
            if let since { params["since"] = since }
            return try OracleWaitCondition(params: params).holds(value)
        }
        #expect(try holds("exists", .null))
        #expect(try holds("absent", JSONValue?.none))
        #expect(try holds("empty", []))
        #expect(try !holds("nonEmpty", ""))
        #expect(try holds("changed", 2, since: 1))
        #expect(try !holds("changed", 1, since: 1))
        // A runner reads an absent pointer as null.
        #expect(try !holds("changed", JSONValue?.none, since: .null))
        #expect(try holds("changed", 1, since: .null))
        #expect(throws: OracleWaitConditionError.since) { try holds("changed", 1) }
        #expect(throws: OracleWaitConditionError.since) { try holds("exists", 1, since: 1) }
        // Facets carry decimals as strings: a numeric string compares as its number.
        #expect(try holds(["op": "gt", "value": 0.5], "0.75"))
        #expect(try holds(["op": "contains", "value": "b"], ["a", "b"]))
        #expect(try holds(["op": "lengthEquals", "value": 2], ["k": 1, "l": 2]))
        #expect(throws: OracleWaitConditionError.test) { try holds(["op": "near", "value": 1], 1) }
    }
}
#endif
