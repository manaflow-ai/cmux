@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// The control router's launch barrier (`ControlRouter.settledLayout`). While the launch layout may still retire a pane
/// the tree lists (Home's first dock move closes the pane Home's page opened in), a method that acts on a pane waits:
/// resolved earlier, the focused pane was the one the move closed, and the open reached the daemon after it ("unknown
/// pane", vw4a-ctl-2 and vw4a-div-2-r2, 2026-11-27). `snapshot.get` answers at once and says `loaded: false`,
/// `settling: true`; past the barrier's deadline nothing ran, and the caller may ask again.
@Suite(.timeLimit(.minutes(1))) struct LaunchLayoutSettleTests {
    static func router(_ executor: RecordingExecutor, settle: Duration = .seconds(10)) -> ControlRouter {
        var configuration = ControlRouter.Configuration.loadTolerant
        configuration.layoutSettleDeadline = settle
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: configuration)
        router.snapshots.publish { snapshot in
            snapshot.catalog = sampleCatalog()
            snapshot.topology.isLoaded = true
            snapshot.topology.daemonState = "connected"
            snapshot.topology.isSettling = true
        }
        return router
    }

    static let run = ControlRequest(id: "1", method: "action.run",
                                    params: ["action": "selectWorkspaceByNumber", "args": ["index": 1], "origin": "script"])

    @Test func snapshotGetAnswersAtOnceAndSaysNotLoadedWhileSettling() async throws {
        let router = Self.router(RecordingExecutor())
        let topology = try await router.handle(ControlRequest(id: "1", method: "snapshot.get", params: [:])).get()["topology"]
        #expect(topology?["loaded"] == .bool(false))
        #expect(topology?["settling"] == .bool(true))
        #expect(topology?["daemon_state"] == .string("connected"))
    }

    @Test func anActionWaitsUntilTheLayoutSettlesThenRuns() async throws {
        let executor = RecordingExecutor()
        let router = Self.router(executor)
        async let answer = router.handle(Self.run)
        // The action reached the barrier: it waits on the snapshot store for a settled layout.
        let deadline = ContinuousClock.now + .seconds(20)
        while !router.snapshots.hasWaiters, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(router.snapshots.hasWaiters, "the action never waited for the launch layout")
        #expect(executor.requests.withLock { $0.isEmpty }, "the action ran while the launch layout was settling")
        router.snapshots.publish { $0.topology.isSettling = false }
        let reply = try await answer.get()
        #expect(reply["ran"] == .bool(true), "\(reply)")
        #expect(executor.requests.withLock { $0.count } == 1)
    }

    @Test func aLayoutThatDoesNotSettleInTimeSaysNothingRan() async {
        let executor = RecordingExecutor()
        let router = Self.router(executor, settle: .milliseconds(100))
        guard case .failure(let error) = await router.handle(Self.run) else {
            Issue.record("the action answered while the layout never settled")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["not_run"]?.boolValue == true)
        #expect(error.data?["state"]?.stringValue == "not_run")
        #expect(executor.requests.withLock { $0.isEmpty })
    }

    @Test func aMethodThatActsOnNoPaneDoesNotWait() async throws {
        let router = Self.router(RecordingExecutor(), settle: .milliseconds(100))
        // action.list acts on no pane: it answers from the snapshot as before, never the barrier's not_run.
        _ = try await router.handle(ControlRequest(id: "1", method: "action.list", params: [:])).get()
        #expect(ControlRouter.layoutDependentMethods.contains("action.run"))
        #expect(!ControlRouter.layoutDependentMethods.contains("snapshot.get"))
    }

    @Test func notSettlingRunsAtOnce() async throws {
        let executor = RecordingExecutor()
        let router = Self.router(executor, settle: .milliseconds(100))
        router.snapshots.publish { $0.topology.isSettling = false }
        let reply = try await router.handle(Self.run).get()
        #expect(reply["ran"] == .bool(true), "\(reply)")
    }
}
