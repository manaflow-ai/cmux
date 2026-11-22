@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// architecture.md 5a: reads never touch the main actor; mutations are
/// bounded and deadlined; no request waits past its deadline.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlLaneTests {
    func makeRouter(executor: any ControlActionExecutor = CountingExecutor(), deadline: Duration = .seconds(2)) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .init(requestDeadline: deadline))
        router.snapshots.publish { $0 = .sample() }
        return router
    }

    /// Stalls the main thread for `duration` and returns once the stall began.
    func stallMainThread(for duration: Duration) async -> Task<Void, Never> {
        let began = Atomic<Bool>(false)
        let task = Task { @MainActor in
            began.store(true, ordering: .releasing)
            spin(for: duration)
        }
        while !began.load(ordering: .acquiring) { await Task.yield() }
        return task
    }

    @Test func readsAnswerFromTheSnapshotWhileTheMainThreadIsStalled() async throws {
        let router = makeRouter()
        let stall = await stallMainThread(for: .milliseconds(600))
        let started = ContinuousClock.now
        let result = try await Task.detached {
            var answers: [JSONValue] = []
            for method in ["system.identify", "snapshot.get", "action.list", "settings.get", "debug.queue"] {
                let params: [String: JSONValue] = method == "settings.get" ? ["path": "appearance.density"] : [:]
                answers.append(try await router.handle(ControlRequest(id: "1", method: method, params: params)).get())
            }
            return answers
        }.value
        let elapsed = ContinuousClock.now - started
        await stall.value
        #expect(elapsed < .milliseconds(300), "reads waited \(elapsed) for the stalled main thread")
        #expect(result[1]["topology"]?["workspaces"]?.arrayValue?.first?["id"] == "ws-1")
        #expect(result[1]["tab_count"] == 1)
        #expect(result[2]["count"] == 4)
        #expect(result[3]["value"] == "compact")
    }

    @Test func aMutationFailsWithTimeoutInsteadOfWaitingOnAStalledMainThread() async throws {
        let executor = CountingExecutor()
        let router = makeRouter(executor: executor, deadline: .milliseconds(200))
        let stall = await stallMainThread(for: .milliseconds(800))
        let started = ContinuousClock.now
        let result = await Task.detached {
            await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "tab-group create", "target": "tab:tab-1"]))
        }.value
        let elapsed = ContinuousClock.now - started
        #expect(result.failure?.code == "timeout")
        #expect(elapsed < .milliseconds(500), "action.run waited \(elapsed)")
        await stall.value
        // The main thread recovered: the timed-out action must not run late.
        for _ in 0..<20 { await Task.yield() }
        await MainActor.run {}
        let calls = executor.calls.load(ordering: .relaxed)
        #expect(calls == 0)
    }

    @Test func mutationsRunOnTheMainActorAndRepublishAfterTheFrame() async throws {
        let executor = CountingExecutor()
        let router = makeRouter(executor: executor)
        let republished = Atomic<Int>(0)
        router.workQueue.setAfterFrame { republished.add(1, ordering: .relaxed) }
        let result = try await router.handle(ControlRequest(id: "1", method: "action.run",
                                                            params: ["action": "tab-group create", "target": "tab:tab-1"])).get()
        #expect(result["ran"] == true)
        let calls = executor.calls.load(ordering: .relaxed)
        #expect(calls == 1)
        await MainActor.run {}
        let republishCount = republished.load(ordering: .relaxed)
        #expect(republishCount == 1)
    }

    @Test func registeredMethodsRunOnTheirLane() async throws {
        let router = makeRouter()
        let onMain = Atomic<Bool>(false)
        router.register([
            .snapshot("test.read") { call in .string(call.snapshot.topology.focus.tabID ?? "") },
            .mainActor("test.write") { _ in
                onMain.store(Thread.isMainThread, ordering: .relaxed)
                return .followUp { .string("sent") }
            },
            .async("test.slow") { _ in
                try await Task.sleep(for: .seconds(30))
                return .null
            },
        ])
        #expect(try await router.handle(ControlRequest(method: "test.read")).get() == "tab-1")
        #expect(try await router.handle(ControlRequest(method: "test.write")).get() == "sent")
        let ranOnMain = onMain.load(ordering: .relaxed)
        #expect(ranOnMain)
        #expect(router.methodNames.contains("test.slow"))
        let fast = ControlRouter(identity: testIdentity(), executor: CountingExecutor(), configuration: .init(requestDeadline: .milliseconds(100)))
        fast.register([.async("test.slow") { _ in
            // Ignores cancellation, like a continuation parked on another process.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return .null
        }])
        let started = ContinuousClock.now
        #expect(await fast.handle(ControlRequest(method: "test.slow")).failure?.code == "timeout")
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }
}
