import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// Records each run's `index` argument in order and refuses the run whose index is `refusing`.
private final class IndexRecordingExecutor: ControlActionExecutor {
    let ran = Mutex<[Int]>([])
    let refusing: Int?
    /// The runs whose work fails, by index. The work is a main-actor task, so it fails only after
    /// every op of the batch's transaction ran (as a daemon command's reply comes after it).
    let failingWork: Set<Int>
    /// Runs on the main actor at the start of each run, with its index (a test's side effect).
    let beforeRun = Mutex<(@MainActor @Sendable (Int) -> Void)?>(nil)

    init(refusing: Int? = nil, failingWork: Set<Int> = []) {
        self.refusing = refusing
        self.failingWork = failingWork
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        guard case .int(let index)? = request.arguments["index"] else { return .disabled }
        beforeRun.withLock { $0 }?(index)
        ran.withLock { $0.append(index) }
        return index == refusing ? .refused("no room") : .ran
    }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let outcome = performAction(request)
        guard case .int(let index)? = request.arguments["index"], failingWork.contains(index) else { return ControlActionRun(outcome: outcome) }
        let work: ActionWork = Task { @MainActor in ActionWorkFailure(refusal: .unavailable, reason: "tab \(index) is gone") }
        return ControlActionRun(outcome: outcome, work: [work])
    }

    var indices: [Int] { ran.withLock { $0 } }
}

/// `action.batch` (CLAUDE.md "Go past Chrome where cmux is scripted"): many app actions in one
/// request apply as one transaction: validated before any runs, run in order in one main-actor
/// work item, bounded, and keyed like `action.run`.
@Suite(.timeLimit(.minutes(1))) struct ActionBatchTests {
    private func router(_ executor: IndexRecordingExecutor, batchOpLimit: Int = ControlRouter.batchOpLimit) -> ControlRouter {
        var configuration = ControlRouter.Configuration.loadTolerant
        configuration.batchOpLimit = batchOpLimit
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

    /// An op's daemon work fails after the ops after it ran (it does not stop them): the answer
    /// names the first op whose work failed with its own action, every op whose work failed, and
    /// how many ops ran, so the client knows which op to look at and that none is safe to resend.
    @Test func anOpWhoseWorkFailsLaterIsNamedWithEveryFailedOpAndHowManyRan() async {
        let executor = IndexRecordingExecutor(failingWork: [2, 3])
        guard case .failure(let error) = await batch(router(executor), ["ops": ops([1, 2, 3])]) else {
            Issue.record("expected op 1's work failure")
            return
        }
        #expect(error.code == "unavailable", "\(error)")
        #expect(error.data?["reason"] == "tab 2 is gone")
        #expect(error.data?["action"] == "selectWorkspaceByNumber")
        #expect(error.data?["op"] == 1, "\(error)")
        #expect(error.data?["failed"] == .array([1, 2]), "a later op's failure is dropped: \(error)")
        #expect(error.data?["applied"] == 3, "every op ran: \(error)")
        #expect(error.data?["not_run"] == false)
        #expect(executor.indices == [1, 2, 3])
    }

    /// An op whose work failed comes before a later op's refusal: the earliest failure answers.
    @Test func anEarlierOpsFailedWorkAnswersBeforeALaterRefusal() async {
        let executor = IndexRecordingExecutor(refusing: 3, failingWork: [1])
        guard case .failure(let error) = await batch(router(executor), ["ops": ops([1, 2, 3])]) else {
            Issue.record("expected op 0's work failure")
            return
        }
        #expect(error.data?["reason"] == "tab 1 is gone", "\(error)")
        #expect(error.data?["op"] == 0, "\(error)")
        #expect(error.data?["applied"] == 2, "op 2 refused, so two ops applied: \(error)")
        #expect(executor.indices == [1, 2, 3])
    }

    /// A router whose work queue drains only when the test fires its frame source.
    private func signalingRouter(_ executor: IndexRecordingExecutor, frames: SignalingFrameSource,
                                 configure: (inout ControlRouter.Configuration) -> Void) -> ControlRouter {
        var configuration = ControlRouter.Configuration.loadTolerant
        configuration.batchOpLimit = 1
        configure(&configuration)
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: configuration, frameSource: frames)
        router.snapshots.publish { snapshot in
            snapshot.catalog = sampleCatalog()
            snapshot.topology.isLoaded = true
        }
        return router
    }

    /// A batch split into transactions (`atomic: false`) whose later transaction never runs (its
    /// deadline passed while it was queued) still records its outcome under its key: a retry with
    /// the key gets that answer at once (how many ops applied), never waits for a run that will
    /// not come. The test drains the queue by hand: transaction 1 runs; transaction 2 is queued and
    /// never drained, so its deadline passes in the queue whatever the machine's speed.
    @Test func aKeyedBatchCutShortByItsDeadlineAnswersARetry() async throws {
        let frames = SignalingFrameSource()
        let executor = IndexRecordingExecutor()
        let router = signalingRouter(executor, frames: frames) { $0.requestDeadline = .seconds(2) }
        var drains = frames.requests.makeAsyncIterator()
        let params: [String: JSONValue] = ["ops": ops([1, 2]), "atomic": false, "idempotency_key": "b-cut"]
        async let answer = batch(router, params)
        _ = await drains.next() // transaction 1 queued
        await MainActor.run { frames.fire() }
        _ = await drains.next() // transaction 2 queued: left there until its deadline passes
        guard case .failure = await answer else {
            Issue.record("expected the deadline to cut the batch short")
            return
        }
        // The request answered at its deadline; the batch ends (its second transaction expired in
        // the queue) and records its outcome under the key.
        let recorded = await router.idempotency.outcome(of: "b-cut")
        guard case .failure(let outcome)? = recorded else {
            Issue.record("the cut-short batch left its key without a failure outcome: \(String(describing: recorded))")
            return
        }
        #expect(outcome.data?["applied"] == 1, "\(outcome)")
        guard case .failure(let retried) = await batch(router, params) else {
            Issue.record("a retry of a cut-short batch ran it again")
            return
        }
        #expect(retried.data?["applied"] == 1, "\(retried)")
        #expect(executor.indices == [1])
    }

    /// A batch split into transactions (`atomic: false`) whose second transaction finds the queue
    /// full (`busy`) after the first applied answers with `applied: 1` and `not_run: false`: a
    /// client trusts `not_run` as safe to send again, and sending it again runs op 1 twice. A retry
    /// with the key replays the same answer, still not `not_run`.
    @Test func aBatchCutShortByAFullQueueIsNotNotRun() async throws {
        let frames = SignalingFrameSource()
        let executor = IndexRecordingExecutor()
        let router = signalingRouter(executor, frames: frames) { $0.queueLimits = MainActorWorkQueue.Limits(maxPending: 1) }
        let queue = router.workQueue
        executor.beforeRun.withLock { hook in
            hook = { index in
                guard index == 1 else { return }
                // While op 1 holds the main actor, an injected key arrives: the queue's one place is
                // taken, so the batch's next transaction is busy. The key's enqueue asks for its drain,
                // which signals this wait; the drain itself waits for the test's last fire.
                let queued = frames.signalOnNextRequest()
                Task.detached { _ = try? await queue.run(method: "filler", workClass: .input, deadline: .now + .seconds(30)) {} }
                queued.wait()
            }
        }
        var drains = frames.requests.makeAsyncIterator()
        let params: [String: JSONValue] = ["ops": ops([1, 2]), "atomic": false, "idempotency_key": "b-busy"]
        async let answer = batch(router, params)
        _ = await drains.next() // transaction 1 queued
        await MainActor.run { frames.fire() }
        guard case .failure(let error) = await answer else {
            Issue.record("expected the full queue to cut the batch short")
            return
        }
        #expect(error.code == "busy", "\(error)")
        #expect(error.data?["applied"] == 1)
        #expect(error.data?["op"] == 1)
        #expect(error.data?["not_run"] == false, "op 1 applied: \(error)")
        #expect(error.data?["state"] == "in_progress")
        #expect(executor.indices == [1])

        guard case .failure(let replayed) = await batch(router, params) else {
            Issue.record("a retry of a cut-short batch ran it again")
            return
        }
        #expect(replayed.data?["applied"] == 1)
        #expect(replayed.data?["not_run"] == false, "the replay of a batch that applied op 1: \(replayed)")
        #expect(executor.indices == [1], "the retry ran ops again")
        await MainActor.run { frames.fire() }
    }

    /// An op's member at the batch level (`origin`, `target`, `focus`) is refused, as `action.run`
    /// refuses an unknown argument: ignored, every op would run with its default (origin `cli`).
    @Test(arguments: ["origin", "target", "focus"])
    func anOpMemberAtTheBatchLevelIsRefusedNotIgnored(member: String) async {
        let executor = IndexRecordingExecutor()
        let value: JSONValue = member == "focus" ? false : (member == "origin" ? "script" : "tab:1")
        guard case .failure(let error) = await batch(router(executor), ["ops": ops([1]), member: value]) else {
            Issue.record("a batch-level \(member) was ignored")
            return
        }
        #expect(error.code == "invalid_params", "\(error)")
        #expect(error.message.contains(member))
        #expect(error.data?["not_run"] == true)
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
