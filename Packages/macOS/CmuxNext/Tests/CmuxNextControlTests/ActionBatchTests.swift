import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Testing

/// Records each run's `index` argument in order and refuses the run whose index is `refusing`.
private final class IndexRecordingExecutor: ControlActionExecutor {
    let ran = Mutex<[Int]>([])
    let refusing: Int?
    /// How long each run holds the main actor (a slow handler).
    let holding: Duration

    init(refusing: Int? = nil, holding: Duration = .zero) {
        self.refusing = refusing
        self.holding = holding
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        guard case .int(let index)? = request.arguments["index"] else { return .disabled }
        spin(for: holding)
        ran.withLock { $0.append(index) }
        return index == refusing ? .refused("no room") : .ran
    }

    var indices: [Int] { ran.withLock { $0 } }
}

/// `action.batch` (CLAUDE.md "Go past Chrome where cmux is scripted"): many app actions in one
/// request apply as one transaction: validated before any runs, run in order in one main-actor
/// work item, bounded, and keyed like `action.run`.
@Suite(.timeLimit(.minutes(1))) struct ActionBatchTests {
    private func router(_ executor: IndexRecordingExecutor, batchOpLimit: Int = ControlRouter.batchOpLimit,
                        deadline: Duration? = nil) -> ControlRouter {
        var configuration = ControlRouter.Configuration.loadTolerant
        configuration.batchOpLimit = batchOpLimit
        if let deadline { configuration.requestDeadline = deadline }
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: configuration)
        router.snapshots.publish { snapshot in
            snapshot.catalog = sampleCatalog()
            snapshot.topology.isLoaded = true
        }
        return router
    }

    private func ops(_ indices: [Int]) -> JSONValue {
        .array(indices.map { ["action": "selectWorkspaceByNumber", "args": ["index": JSONValue($0)]] })
    }

    private func batch(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "action.batch", params: params))
    }

    @Test func everyOpRunsInOrderInOneWorkItem() async throws {
        let executor = IndexRecordingExecutor()
        let router = router(executor)
        let reply = try await batch(router, ["ops": ops([1, 2, 3])]).get()
        #expect(executor.indices == [1, 2, 3])
        #expect(router.workQueue.stats.executed == 1, "one main-actor work item for the whole batch")
        #expect(reply["ran"] == 3)
    }

    @Test func oneInvalidOpRunsNothing() async {
        let executor = IndexRecordingExecutor()
        guard case .failure(let error) = await batch(router(executor), ["ops": ops([1, 42, 3])]) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(error.data?["op"] == 1)
        #expect(error.data?["not_run"] == true)
        #expect(executor.indices.isEmpty)
    }

    @Test func aBatchOverTheLimitIsRefusedNamingTheLimit() async {
        let executor = IndexRecordingExecutor()
        guard case .failure(let error) = await batch(router(executor, batchOpLimit: 2), ["ops": ops([1, 2, 3])]) else {
            Issue.record("expected batch_too_large")
            return
        }
        #expect(error.code == "batch_too_large")
        #expect(error.data?["limit"] == 2)
        #expect(error.data?["not_run"] == true)
        #expect(executor.indices.isEmpty)
    }

    @Test func atomicFalseRunsALargeBatchAsConsecutiveTransactions() async throws {
        let executor = IndexRecordingExecutor()
        let router = router(executor, batchOpLimit: 2)
        let reply = try await batch(router, ["ops": ops([1, 2, 3]), "atomic": false]).get()
        #expect(executor.indices == [1, 2, 3])
        #expect(router.workQueue.stats.executed == 2, "two transactions of at most two ops")
        #expect(reply["ran"] == 3)
    }

    @Test func aRefusalAtRunTimeStopsTheBatchThere() async {
        let executor = IndexRecordingExecutor(refusing: 2)
        guard case .failure(let error) = await batch(router(executor), ["ops": ops([1, 2, 3])]) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["op"] == 1)
        #expect(error.data?["applied"] == 1)
        #expect(error.data?["not_run"] == nil, "the op before it ran")
        #expect(executor.indices == [1, 2])
    }

    /// A batch split into transactions (`atomic: false`) whose later transaction never runs (its
    /// deadline passed while the earlier one held the main actor) still records its outcome under
    /// its key: a retry with the key gets that answer at once (how many ops applied), never waits
    /// for a run that will not come.
    @Test func aKeyedBatchCutShortByItsDeadlineAnswersARetry() async throws {
        let executor = IndexRecordingExecutor(holding: .milliseconds(400))
        let router = router(executor, batchOpLimit: 1, deadline: .milliseconds(200))
        let params: [String: JSONValue] = ["ops": ops([1, 2]), "atomic": false, "idempotency_key": "b-cut"]
        guard case .failure = await batch(router, params) else {
            Issue.record("expected the deadline to cut the batch short")
            return
        }
        // The request answered at its deadline while the batch still ran; the batch ends (its second
        // transaction expires in the queue) and records its outcome under the key.
        let end = ContinuousClock.now + .seconds(10)
        while !router.idempotency.hasOutcome("b-cut"), ContinuousClock.now < end { await Task.yield() }
        try #require(router.idempotency.hasOutcome("b-cut"), "the cut-short batch left its key without an outcome")
        let started = ContinuousClock.now
        guard case .failure(let retried) = await batch(router, params) else {
            Issue.record("a retry of a cut-short batch ran it again")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(5), "the retry waited for the cut-short run")
        #expect(retried.data?["applied"] == 1, "\(retried)")
        #expect(executor.indices == [1])
    }

    @Test func aBatchLevelMemberOnOneOpIsRefused() async {
        let executor = IndexRecordingExecutor()
        let op: JSONValue = ["action": "selectWorkspaceByNumber", "args": ["index": 1], "wait": false]
        guard case .failure(let error) = await batch(router(executor), ["ops": [op]]) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(error.data?["op"] == 0)
        #expect(executor.indices.isEmpty)
    }

    @Test func aRetryWithTheKeyReplaysAndAnotherBatchWithItConflicts() async throws {
        let executor = IndexRecordingExecutor()
        let router = router(executor)
        _ = try await batch(router, ["ops": ops([1, 2]), "idempotency_key": "b-1"]).get()
        let again = try await batch(router, ["ops": ops([1, 2]), "idempotency_key": "b-1"]).get()
        #expect(again["replayed"] == true)
        #expect(executor.indices == [1, 2])
        guard case .failure(let error) = await batch(router, ["ops": ops([3]), "idempotency_key": "b-1"]) else {
            Issue.record("expected idempotency_conflict")
            return
        }
        #expect(error.code == "idempotency_conflict")
    }
}
