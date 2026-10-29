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
///   build, and none in the change's own turn; readers keep the last published value meanwhile;
/// - the publish never runs while the person's input response is open (it waits for the frame they wait for), a
///   person-caused daemon batch that only moves the sequences included;
/// - a reader waiting on its write barrier raises the pending publish to `automation`, also when it started waiting
///   after the change (`action.run` awaits the daemon's idle first, `after: "sync"` its round trip): during launch,
///   which holds background work until reveal, the barrier still resolves, in an automation task;
/// - a read after a CLI write builds the snapshot in one `automation` task;
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

        /// Runs the main-actor hops a change queued (the info cache's) and the main run loop's blocks (a waiting
        /// reader's post from its own thread reaches main as one), with no frame.
        func hops() async {
            for _ in 0..<8 {
                await Task.yield()
                runLoopPass()
            }
        }

        /// One main run loop pass; synchronous, because `RunLoop.run` is unavailable from async contexts.
        private func runLoopPass() { _ = RunLoop.main.run(mode: .default, before: Date()) }

        func stop() {
            publisher.stop()
            keeper.deactivate()
        }
    }

    /// One workspace with one tab and a started publisher; its first (background) publish done unless `launching`,
    /// which holds background work as the app's launch does until reveal.
    ///
    /// The publisher hears its notices on a private notification center (`appEvents`, else one of its own): in the
    /// full parallel run the windows other suites open, key and close post on the default one, and each publish
    /// counted as a build here (4 and 11 extra builds, jobs 122238887723 and 122242789085).
    private static func rig(launching: Bool = false, appEvents: AppEvents? = nil) async -> Rig {
        _ = NSApplication.shared
        let clock = LazyPublishClock()
        // The reveal deadline is out of the test's reach: only the test's own steps move the phase.
        let startup = launching ? StartupPhase(ledger: WakeupLedger(), timing: .init(revealDeadline: .seconds(3_600),
                                                                                       settleFailsafe: .seconds(7_200)))
            : StartupPhase.settled()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), startup: startup) { _ in LazyPublishFakeLink() }
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
        let publisher = ControlSnapshotPublisher(router: router, services: services,
                                                 appEvents: appEvents ?? AppEvents(center: NotificationCenter()))
        publisher.start()
        let rig = Rig(clock: clock, work: work, keeper: keeper, services: services, router: router, publisher: publisher)
        #expect(publisher.builds == 0, "start built the snapshot in its own turn")
        await rig.hops()
        rig.frame()
        await rig.hops()
        rig.frame()
        if launching {
            #expect(publisher.builds == 0, "the first background publish ran during launch")
        } else {
            #expect(publisher.builds >= 1, "the first background publish did not run")
            #expect(!router.snapshots.isStale)
        }
        return rig
    }

    /// Waits in the store for a snapshot `isReady` accepts while the test fires frames, as the app's display link
    /// would; nil when it never came in 200 frames.
    private static func waitFor(_ rig: Rig, _ isReady: @escaping @Sendable (ControlSnapshot) -> Bool) async -> ControlSnapshot? {
        let reply = LazyPublishSnapshot()
        let store = rig.router.snapshots
        let task = Task { @MainActor in
            reply.value = await store.snapshot(where: isReady, deadline: .now + .seconds(30))
            reply.done = true
        }
        for _ in 0..<200 where !reply.done {
            await rig.hops()
            rig.frame()
        }
        task.cancel()
        await task.value
        return reply.value
    }

    /// Reads `method` through the router while the test fires frames, as the app's display link would: the read's
    /// build waits for its automation task.
    private static func read(_ rig: Rig, _ method: String = "snapshot.get") async -> Result<CmuxNextSettings.JSONValue, ControlError> {
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
        // A plain read keeps the last published value: it does not wait for a main-thread build of a change it did
        // not ask for (only a work-queue frame marks the store stale).
        #expect(!rig.router.snapshots.isStale, "a model change made every read wait for a main-thread build")
        #expect(rig.title != "t49")
        rig.frame()
        #expect(rig.builds - builds == 1, "\(rig.builds - builds) builds for 50 changes in one frame (want 1)")
        #expect(rig.title == "t49")
        await rig.hops()
        rig.frame()
        #expect(rig.builds - builds == 1, "the publish queued another build with nothing changed")
    }

    /// Key windows are not observable: their notices reach the publisher through the app's one AppEvents (FG307,
    /// recipe R-notif), one subscription per name while it runs. A burst of notices gives one background build on the
    /// next frame, none in the notices' own turn; `stop` ends the subscriptions.
    @Test func keyWindowNoticesQueueOnePublishThroughAppEvents() async {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let rig = await Self.rig(appEvents: events)
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 1, "the publisher did not subscribe to the key-window notice")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        let builds = rig.builds
        for _ in 0..<10 {
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            center.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        #expect(rig.builds == builds, "a notice built the snapshot in its own turn")
        await rig.hops()
        rig.frame()
        #expect(rig.builds - builds == 1, "\(rig.builds - builds) builds for one turn of notices (want 1)")
        rig.stop()
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 0, "stop kept the subscription")
        #expect(!events.isObserving(NSApplication.didResignActiveNotification), "stop kept the app's observer")
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

    /// A person-caused daemon batch that only moves the sequences publishes after the person's frame, not in the
    /// input-response pass before the commit.
    @Test func aPersonCausedSequenceBatchNeverPublishesInsideAnInputResponse() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        let published = rig.publisher.sequencePublishes
        let target = rig.store.appliedSequence + 3
        rig.work.noteDiscreteInput(expectsFrame: true)
        rig.work.causes.withCause(.person) { rig.store.advanceAppliedSequence(to: target) }
        await rig.hops()
        #expect(rig.work.budget.isInputResponseOpen)
        rig.frame()
        #expect(rig.publisher.sequencePublishes == published, "the sequence publish ran inside the input response")
        #expect(rig.router.snapshots.current.topology.daemonSequence < target)
        rig.work.renderPassEnded(nanos: 1_000_000)
        rig.clock.advance(ms: 600)
        rig.frame()
        #expect(rig.publisher.sequencePublishes - published == 1, "the sequences were not published once the response closed")
        #expect(rig.router.snapshots.current.topology.daemonSequence == target)
    }

    /// A read after a CLI write (a work-queue frame marks the store stale) waits as a reader: its build is one
    /// automation task, and it runs during launch, while background work is held.
    @Test func aReadAfterACLIWriteBuildsInOneAutomationTask() async throws {
        let rig = await Self.rig(launching: true)
        defer { rig.stop() }
        try await rig.router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        let (automation, background) = (rig.work.budget.stats.tasks[1], rig.work.budget.stats.tasks[2])
        let reply = await Self.read(rig)
        #expect((try? reply.get()) != nil, "the read failed: \(reply)")
        #expect(rig.builds == 1, "\(rig.builds) builds for one read (want 1)")
        #expect(rig.work.budget.stats.tasks[1] > automation, "the read's build was not an automation task")
        #expect(rig.work.budget.stats.tasks[2] == background, "the read's build ran as background work")
        #expect(!rig.router.snapshots.isStale)
    }

    /// `action.run`'s order: the daemon's echo is applied (its publish queued as background work), then the reader
    /// starts waiting on its barrier. The wait raises the publish to automation: during launch, which holds
    /// background work until reveal, the barrier still resolves.
    @Test func aBarrierThatWaitsAfterTheEchoRaisesThePublishToAutomation() async {
        let rig = await Self.rig(launching: true)
        defer { rig.stop() }
        _ = await Self.read(rig)
        #expect(rig.builds == 1, "the first read did not build the snapshot")
        rig.store.apply(.titleChanged(surface: 1, title: "echo"))
        await rig.hops()
        rig.frame()
        #expect(rig.builds == 1, "the background publish ran during launch")
        #expect(rig.title != "echo")
        let (automation, background) = (rig.work.budget.stats.tasks[1], rig.work.budget.stats.tasks[2])
        let snapshot = await Self.waitFor(rig) { $0.topology.workspaces.first?.panes.first?.tabs.first?.title == "echo" }
        #expect(snapshot != nil, "the barrier never resolved: its publish stayed background work")
        #expect(rig.builds == 2, "\(rig.builds - 1) builds for the barrier (want 1)")
        #expect(rig.work.budget.stats.tasks[1] > automation, "the barrier's publish was not an automation task")
        #expect(rig.work.budget.stats.tasks[2] == background, "the barrier's publish ran as background work")
    }

    /// The usual `after: "sync"` result: a daemon batch that only moves the sequence, then a reader waiting for that
    /// sequence. Its sequence-only publish is raised to automation too (no topology build), during launch as well.
    @Test func aSequenceOnlyBarrierRaisesItsPublishToAutomation() async {
        let rig = await Self.rig(launching: true)
        defer { rig.stop() }
        _ = await Self.read(rig)
        let published = rig.publisher.sequencePublishes
        let target = rig.store.appliedSequence + 5
        rig.store.advanceAppliedSequence(to: target)
        await rig.hops()
        rig.frame()
        #expect(rig.router.snapshots.current.topology.daemonSequence < target, "the background publish ran during launch")
        let automation = rig.work.budget.stats.tasks[1]
        let snapshot = await Self.waitFor(rig) { $0.topology.daemonSequence >= target }
        #expect(snapshot != nil, "the barrier never resolved: its sequence publish stayed background work")
        #expect(rig.builds == 1, "\(rig.builds - 1) topology builds for a sequence-only barrier (want 0)")
        #expect(rig.publisher.sequencePublishes - published == 1)
        #expect(rig.work.budget.stats.tasks[1] > automation, "the barrier's sequence publish was not an automation task")
    }

    /// A liveness diagnostic answers from the last published snapshot: it never waits for a stale snapshot's build,
    /// a main-thread task, so it answers while the main thread is stalled.
    @Test func aPingDoesNotWaitForAStaleSnapshotsBuild() async throws {
        let rig = await Self.rig()
        defer { rig.stop() }
        try await rig.router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        let builds = rig.builds
        // No frame fires: a ping that waited for the build would never answer.
        let reply = await rig.router.handle(ControlRequest(method: "system.ping"))
        #expect((try? reply.get()) != nil, "the ping failed: \(reply)")
        #expect(rig.builds == builds)
        #expect(rig.router.snapshots.isStale)
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
    var value: Result<CmuxNextSettings.JSONValue, ControlError>?
}

/// A store wait's result, set on the main actor by the task that waits.
@MainActor
private final class LazyPublishSnapshot {
    var value: ControlSnapshot?
    var done = false
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
