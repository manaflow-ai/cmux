@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// Opens a command ticket in the action's scope from a task the handler
/// starts, as `DaemonService` does, and closes it when the test opens the gate.
final class ScopedCommandExecutor: ControlActionExecutor {
    let calls = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let opened = Atomic<Bool>(false)
    let barrier: UInt64
    let created: [ControlCreatedObject]
    let failure: ControlCommandScope.Failure?
    let mutationIDs = Mutex<[String]>([])

    init(barrier: UInt64 = 5, created: [ControlCreatedObject] = [], failure: ControlCommandScope.Failure? = nil) {
        self.barrier = barrier
        self.created = created
        self.failure = failure
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        calls.add(1, ordering: .relaxed)
        // A plain Task, not tracked by anyone: the scope still sees it.
        Task { @MainActor in
            let scope = ControlCommandScope.current
            let ticket = scope?.begin()
            if let id = scope?.nextMutationID() { self.mutationIDs.withLock { $0.append(id) } }
            self.started.store(true, ordering: .relaxed)
            await self.waitForGate()
            scope?.noteCreated(self.created)
            if self.failure == nil { scope?.noteBarrier(self.barrier, machine: ControlCommandScope.localMachine) }
            scope?.end(ticket, failure: self.failure)
        }
        return ControlActionRun(outcome: .ran)
    }

    private func waitForGate() async {
        await withCheckedContinuation { continuation in
            let open = gate.withLock { stored -> Bool in
                if opened.load(ordering: .relaxed) { return true }
                stored = continuation
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiter = gate.withLock { stored -> CheckedContinuation<Void, Never>? in
            opened.store(true, ordering: .relaxed)
            defer { stored = nil }
            return stored
        }
        waiter?.resume()
    }
}

/// `action.run` waits by default for every daemon command its handler sent
/// (from any task), then for a snapshot that reflects their echoes, and
/// reports the created objects by public id (state-ownership.md 4).
@Suite(.timeLimit(.minutes(1))) struct ActionRunContractTests {
    func makeRouter(_ executor: any ControlActionExecutor, deadline: Duration = .seconds(10),
                    limits: MainActorWorkQueue.Limits = MainActorWorkQueue.Limits(),
                    frames: any ControlFrameSource = MainQueueFrameSource()) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor,
                                   configuration: ControlRouter.Configuration(requestDeadline: deadline, queueLimits: limits),
                                   frameSource: frames)
        router.snapshots.publish { snapshot in
            snapshot = ControlSnapshot.sample()
            snapshot.topology.workspaces[0].resourceID = "ws_0a1b2c"
        }
        return router
    }

    func run(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["action"] = params["action"] ?? "tab-group create"
        return await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
    }

    func waitUntil(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { await Task.yield() } // test-only wait
    }

    @Test func waitsForTheScopeThenForTheSnapshotAndReportsCreatedPublicIDs() async throws {
        let executor = ScopedCommandExecutor(barrier: 9, created: [ControlCreatedObject(.workspace, "ws-1"), ControlCreatedObject(.tab, "11")])
        let router = makeRouter(executor)
        let done = Atomic<Bool>(false)
        let reply = Task {
            defer { done.store(true, ordering: .relaxed) }
            return await run(router, ["target": "tab:tab-1"])
        }
        await waitUntil { executor.started.load(ordering: .relaxed) }
        let answeredEarly = done.load(ordering: .relaxed)
        #expect(!answeredEarly, "answered before the handler's command replied")
        executor.open()
        // The command replied; the store has not applied its echo yet.
        await waitUntil { router.snapshots.hasWaiters }
        let answeredBeforeEcho = done.load(ordering: .relaxed)
        #expect(!answeredBeforeEcho, "answered before the snapshot reflected the echo")
        router.snapshots.publish { $0.topology.daemonSequence = 9 }
        let result = try await reply.value.get()
        #expect(result["ran"] == true)
        #expect(result["waited"] == true)
        #expect(result["created"] == ["ws_0a1b2c", "tab-1"])
        #expect(result["sequence"] == 9)
        #expect(result["target"] == "tab:tab-1")
        #expect(result["resolved"]?["id"] == "tab-1")
    }

    @Test func waitFalseAnswersBeforeTheWork() async throws {
        let executor = ScopedCommandExecutor()
        let router = makeRouter(executor)
        let result = try await run(router, ["target": "tab:tab-1", "wait": false]).get()
        #expect(result["waited"] == false)
        #expect(result["created"] == [])
        executor.open()
    }

    @Test func aDaemonRejectionFailsTheRun() async {
        let executor = ScopedCommandExecutor(failure: ControlCommandScope.Failure(label: "rename", message: "rename: no such tab"))
        let router = makeRouter(executor)
        executor.open()
        guard case .failure(let error) = await run(router, ["target": "tab:tab-1"]) else {
            Issue.record("a rejected command reported success")
            return
        }
        #expect(error.code == "daemon_error")
        #expect(error.message == "rename: no such tab")
    }

    @Test func aCommandThatMayStillApplyIsInProgress() async {
        let executor = ScopedCommandExecutor(failure: ControlCommandScope.Failure(label: "rename", message: "rename: timed out", mayHaveApplied: true))
        let router = makeRouter(executor)
        executor.open()
        guard case .failure(let error) = await run(router, ["target": "tab:tab-1"]) else {
            Issue.record("a timed-out command reported success")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["state"] == "in_progress")
        #expect(error.data?["not_run"] == false)
    }

    @Test func aStartedRunThatMissesItsDeadlineIsInProgress() async throws {
        let executor = ScopedCommandExecutor()
        let frames = ManualFrameSource()
        // The deadline leaves a loaded runner room to start the handler;
        // the frames stop firing a second before it.
        let router = makeRouter(executor, deadline: .seconds(5), frames: frames)
        let reply = Task { await run(router, ["target": "tab:tab-1"]) }
        // The handler runs as soon as the frame fires: the run has started.
        let end = ContinuousClock.now + .seconds(4)
        while executor.calls.load(ordering: .relaxed) == 0, ContinuousClock.now < end { await MainActor.run { frames.fire() } } // test-only wait
        let calls = executor.calls.load(ordering: .relaxed)
        try #require(calls == 1, "the handler never ran before the deadline (a loaded machine)")
        guard case .failure(let error) = await reply.value else {
            Issue.record("expected a timeout")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["state"] == "in_progress")
        #expect(error.data?["not_run"] == false)
        executor.open()
    }

    @Test func aRunThatExpiresInTheQueueIsNotRunAndNeverRuns() async {
        let executor = ScopedCommandExecutor()
        let frames = ManualFrameSource()
        let router = makeRouter(executor, deadline: .milliseconds(100), frames: frames)
        guard case .failure(let error) = await run(router, ["target": "tab:tab-1"]) else {
            Issue.record("expected a timeout")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["state"] == "not_run")
        #expect(error.data?["not_run"] == true)
        await MainActor.run { frames.fire() }
        let calls = executor.calls.load(ordering: .relaxed)
        #expect(calls == 0)
    }

    @Test func busyIsNotRun() async {
        let router = makeRouter(ScopedCommandExecutor(), limits: MainActorWorkQueue.Limits(maxPending: 0))
        guard case .failure(let error) = await run(router, ["target": "tab:tab-1"]) else {
            Issue.record("expected busy")
            return
        }
        #expect(error.code == "busy")
        #expect(error.data?["not_run"] == true)
        #expect(error.data?["state"] == "not_run")
    }

    @Test func aRetryWithTheSameKeyReplaysAndDerivesTheSameMutationIDs() async throws {
        let executor = ScopedCommandExecutor()
        executor.open()
        let router = makeRouter(executor)
        router.snapshots.publish { $0.topology.daemonSequence = 5 }
        let params: [String: JSONValue] = ["target": "tab:tab-1", "idempotency_key": "k-1", "args": ["name": "API"]]
        let first = try await run(router, params).get()
        let second = try await run(router, params).get()
        let calls = executor.calls.load(ordering: .relaxed)
        #expect(calls == 1)
        #expect(first["replayed"] == nil)
        #expect(second["replayed"] == true)
        #expect(second["sequence"] == first["sequence"])
        // The same key on a fresh app derives the same daemon mutation id.
        let fresh = makeRouter(executor)
        fresh.snapshots.publish { $0.topology.daemonSequence = 5 }
        _ = try await run(fresh, params).get()
        let ids = executor.mutationIDs.withLock { $0 }
        #expect(ids.count == 2 && ids[0] == ids[1])

        guard case .failure(let conflict) = await run(router, ["target": "tab:tab-1", "idempotency_key": "k-1", "args": ["name": "Other"]]) else {
            Issue.record("a different request with the same key ran")
            return
        }
        #expect(conflict.code == "idempotency_conflict")
    }

    @Test func aRunThatNeverStartedLeavesNoReplayForItsKey() async throws {
        let frames = ManualFrameSource()
        let executor = ScopedCommandExecutor()
        executor.open()
        let router = makeRouter(executor, deadline: .milliseconds(100), frames: frames)
        let params: [String: JSONValue] = ["target": "tab:tab-1", "idempotency_key": "k-2"]
        #expect((await run(router, params)).failure?.data?["not_run"] == true)
        // The queue drops the item at the same deadline; then the key is free.
        await waitUntil { router.idempotency.count == 0 }
        #expect(router.idempotency.count == 0)
    }

    @Test func cliRunsResolveOnlyCLINamesOfCLIActions() async throws {
        var catalog = sampleCatalog()
        catalog.actions[0].isCLI = true
        let router = makeRouter(RecordingExecutor())
        router.updateCatalog(ControlCatalog(actions: catalog.actions, aliases: catalog.aliases, targetKinds: catalog.targetKinds,
                                            debugActionsAvailable: true))
        let list = try await router.handle(ControlRequest(id: "1", method: "action.list")).get()
        #expect(list["actions"]?.arrayValue?.first?["cli"] == true)
        #expect(list["actions"]?.arrayValue?.last?["cli"] == false)
        #expect((try await run(router, ["action": "tab-group create", "cli": true, "target": "tab:tab-1", "wait": false]).get())["ran"] == true)
        for name in ["tabGroup.create", "workspace select-number"] {
            let result = await run(router, ["action": .string(name), "cli": true, "args": ["index": 1]])
            #expect(result.failure?.code == "not_found", "\(name)")
        }
    }
}

