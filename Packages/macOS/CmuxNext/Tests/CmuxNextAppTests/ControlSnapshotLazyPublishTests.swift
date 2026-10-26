import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The control snapshot off the visible path (plans/cmux-next/chrome-parity/p06-scheduler.md, task 039), on a test
/// ``MainWorkScheduler`` whose frames the test fires by hand:
/// - a change marks the snapshot dirty and queues one `background` publish: 50 changes before that task runs give one
///   build, and none in the change's own turn;
/// - the publish never runs while the person's input response is open (it waits for the frame they wait for);
/// - a read that needs the snapshot fresh builds it in one `automation` task of its own, and the queued background
///   publish then builds nothing;
/// - a control work-queue frame (a script's CLI calls, 1000 a second under load) only marks the snapshot stale: each
///   drained frame mapped the topology and walked every mounted pane on the main thread, and the separate
///   `control.publish` task each frame paid is gone. The snapshot is built when a read needs it, once for any number
///   of frames before that read, and still covers the writes those frames made (read-your-writes).
@MainActor @Suite(.serialized)
struct ControlSnapshotLazyPublishTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// The control work queue's frames on the test scheduler's budget, each on the next main-actor turn, as the app's
    /// control frames are on its budget.
    final class BudgetedSoonFrames: ControlFrameSource {
        // Read only on the main actor (mainFrameBudget); the budget is a main-actor class made there.
        nonisolated(unsafe) private let budgetRef: MainFrameBudget
        let mainTaskBoard: MainTaskBoard?

        @MainActor init(budget: MainFrameBudget) {
            budgetRef = budget
            mainTaskBoard = budget.board
        }

        @MainActor var mainFrameBudget: MainFrameBudget? { budgetRef }
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    private struct Rig {
        let clock: LazyPublishClock
        let work: MainWorkScheduler
        let keeper: FrameClient
        let services: AppServices
        let router: ControlRouter
        let publisher: ControlSnapshotPublisher
        var store: DaemonStore { services.daemon.store }
        var builds: Int { publisher.builds }
        var title: String? { router.snapshots.current.topology.workspaces.first?.panes.first?.tabs.first?.title }

        /// One display frame, a frame's time after the last one.
        func frame() {
            clock.advance(ms: 17)
            work.frameDidFire(timestamp: clock.seconds, refreshInterval: 1.0 / 60)
        }

        /// Runs the main-actor hops a change queued (the info cache's), with no frame.
        func hops() async {
            for _ in 0..<8 { await Task.yield() }
        }

        func stop() {
            publisher.stop()
            keeper.deactivate()
        }
    }

    /// One workspace with one tab, a started publisher, its first (background) publish done.
    private static func rig() async -> Rig {
        _ = NSApplication.shared
        let clock = LazyPublishClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in LazyPublishFakeLink() }
        // Keeps the fake link up, so a post waits for a frame the test fires instead of a run loop turn.
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: work)
        let store = services.daemon.store
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1))])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1",
                                                                        screens: [screen])]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)),
                                   frameSource: BudgetedSoonFrames(budget: work.budget))
        let publisher = ControlSnapshotPublisher(router: router, services: services)
        publisher.start()
        let rig = Rig(clock: clock, work: work, keeper: keeper, services: services, router: router, publisher: publisher)
        #expect(publisher.builds == 0, "start built the snapshot in its own turn")
        await rig.hops()
        rig.frame()
        await rig.hops()
        rig.frame()
        #expect(publisher.builds >= 1, "the first background publish did not run")
        #expect(!router.snapshots.isStale)
        return rig
    }

    /// Reads `method` through the router while the test fires frames, as the app's display link would: the read's
    /// build waits for its automation task.
    private static func read(_ rig: Rig, _ method: String = "system.ping") async -> Result<JSONValue, ControlError> {
        let reply = LazyPublishReply()
        let router = rig.router
        let task = Task { @MainActor in reply.value = await router.handle(ControlRequest(method: method)) }
        for _ in 0..<200 where reply.value == nil {
            await rig.hops()
            rig.frame()
        }
        await task.value
        return reply.value ?? .failure(ControlError(code: "test_timeout", message: "the read never finished"))
    }

    /// 50 changes before the publish task runs: nothing built in their turns, one background build on the next frame.
    @Test func fiftyChangesInAFrameGiveOnePublish() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.builds
        for index in 0..<50 { rig.store.apply(.titleChanged(surface: 1, title: "t\(index)")) }
        await rig.hops()
        #expect(rig.builds == builds, "\(rig.builds - builds) builds in the changes' own turns (want 0)")
        #expect(rig.router.snapshots.isStale, "the changes did not mark the snapshot dirty for readers")
        rig.frame()
        #expect(rig.builds - builds == 1, "\(rig.builds - builds) builds for 50 changes in one frame (want 1)")
        #expect(rig.title == "t49")
        await rig.hops()
        rig.frame()
        #expect(rig.builds - builds == 1, "the publish queued another build with nothing changed")
    }

    /// A change while the person's key waits for its frame: the publish yields through that frame and runs after it.
    @Test func thePublishNeverRunsInsideAnInputResponse() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.builds
        let budget = rig.work.budget
        let yielded = budget.stats.yieldedToInputResponse[2]
        rig.work.noteDiscreteInput(expectsFrame: true)
        for index in 0..<50 { rig.store.apply(.titleChanged(surface: 1, title: "typed\(index)")) }
        await rig.hops()
        #expect(budget.isInputResponseOpen)
        rig.frame()
        #expect(rig.builds == builds, "the publish ran inside the input response")
        #expect(budget.stats.yieldedToInputResponse[2] > yielded, "the background publish never met the open response")
        rig.work.renderPassEnded(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the tick's render pass did not close the response")
        // Past the typing burst, so the background rate of the burst plays no part.
        rig.clock.advance(ms: 600)
        rig.frame()
        #expect(rig.builds - builds == 1, "\(rig.builds - builds) builds once the response closed (want 1)")
        #expect(rig.title == "typed49")
    }

    /// A read that finds the snapshot dirty builds it in one automation task for its request; the queued background
    /// publish then has nothing left to build.
    @Test func aFreshReadPromotesThePublishToAutomation() async throws {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.builds
        let automationTasks = rig.work.budget.stats.tasks[1]
        rig.store.apply(.titleChanged(surface: 1, title: "read me"))
        await rig.hops()
        #expect(rig.builds == builds)
        let reply = LazyPublishReply()
        let router = rig.router
        let read = Task { @MainActor in reply.value = await router.handle(ControlRequest(method: "snapshot.get")) }
        await rig.hops()
        #expect(rig.builds == builds, "the read built the snapshot outside a scheduled task")
        // One frame: the read's automation task builds, ahead of the background one queued before it.
        rig.frame()
        #expect(rig.builds - builds == 1, "\(rig.builds - builds) builds in the read's frame (want 1)")
        #expect(rig.work.budget.stats.tasks[1] > automationTasks, "the read's build was not an automation task")
        #expect(rig.title == "read me")
        for _ in 0..<200 where reply.value == nil {
            await rig.hops()
            rig.frame()
        }
        await read.value
        #expect((try? reply.value?.get()) != nil, "the read failed: \(String(describing: reply.value))")
        rig.frame()
        #expect(rig.builds - builds == 1, "the queued background publish built again after the read's build")
    }

    /// On the app's budget, a burst of CLI writes with no reader builds no snapshot and charges one automation task
    /// per write, none for a publish: a work-queue frame only marks the snapshot stale, inside its own drain.
    @Test func budgetedWorkQueueFramesWithNoReaderBuildNothingAndChargeNoPublishTask() async throws {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.builds
        let tasks = rig.work.budget.stats.tasks[1]

        for _ in 0..<100 {
            try await rig.router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        }
        await rig.hops()
        rig.frame()
        #expect(rig.builds == builds, "\(rig.builds - builds) snapshot builds for 100 work-queue frames with no reader (want 0)")
        #expect(rig.work.budget.stats.tasks[1] - tasks == 100,
                "\(rig.work.budget.stats.tasks[1] - tasks) automation tasks for 100 writes (want 100: one per write, no publish task)")
        #expect(rig.router.snapshots.isStale, "the frames did not mark the snapshot stale")
    }

    @Test func workQueueFramesWithNoReaderBuildNothingAndOneReadBuildsOnce() async throws {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.builds

        for _ in 0..<100 {
            try await rig.router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        }
        await rig.hops()
        rig.frame()
        #expect(rig.builds == builds, "\(rig.builds - builds) snapshot builds for 100 work-queue frames with no reader (want 0)")

        // One read: the snapshot is built for it, once.
        let reply = await Self.read(rig)
        #expect((try? reply.get()) != nil)
        #expect(rig.builds == builds + 1, "\(rig.builds - builds) builds for one read after the frames (want 1)")
        // A second read with nothing changed builds nothing.
        _ = await Self.read(rig)
        #expect(rig.builds == builds + 1)
    }
}

/// A read's reply, set on the main actor by the task that reads.
@MainActor
private final class LazyPublishReply {
    var value: Result<JSONValue, ControlError>?
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class LazyPublishClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
    /// The clock in seconds, as a frame's timestamp.
    var seconds: CFTimeInterval { CFTimeInterval(now) / 1_000_000_000 }
}

@MainActor
private final class LazyPublishFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
