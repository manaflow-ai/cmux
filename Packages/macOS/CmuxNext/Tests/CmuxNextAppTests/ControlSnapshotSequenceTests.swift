import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The control snapshot publisher's work per daemon change, on a test ``MainWorkScheduler`` whose display frames the
/// test fires itself (no display link in a test process, no clock, no wait for time to pass):
/// - a daemon batch that changes nothing the topology shows (a busy terminal's activity, a status tick in another
///   workspace) moves the published sequence, so a CLI read waiting on its write barrier still wakes, but maps no
///   topology: each such batch rebuilt it (10 printing terminals in STRESS; perf-lead.md issue 5);
/// - a model change publishes in one background task on the next frame: it waited for 100 ms after the last
///   publish (`modelChangeInterval`), asking for a frame on every display frame until then.
@MainActor @Suite(.serialized)
struct ControlSnapshotSequenceTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    private struct Rig {
        let work: MainWorkScheduler
        let keeper: FrameClient
        let services: AppServices
        let router: ControlRouter
        let publisher: ControlSnapshotPublisher
        var store: DaemonStore { services.daemon.store }

        func stop() {
            publisher.stop()
            keeper.deactivate()
        }
    }

    /// One workspace with one tab, a started publisher on a hand-fired scheduler, its first publish done.
    private static func rig() async -> Rig {
        _ = NSApplication.shared
        let work = MainWorkScheduler.testing { _ in SequenceFakeLink() }
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
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        let publisher = ControlSnapshotPublisher(router: router, services: services)
        publisher.start()
        let rig = Rig(work: work, keeper: keeper, services: services, router: router, publisher: publisher)
        await Self.settle(rig)
        return rig
    }

    /// Runs the main-actor work the change queued (observation hops) and a few frames for the tasks it posted: a
    /// bounded number of turns, never a wait for time.
    private static func settle(_ rig: Rig) async {
        for _ in 0..<4 {
            for _ in 0..<8 { await Task.yield() }
            rig.work.frameDidFire()
        }
    }

    @Test func aBatchThatChangesNoTopologyOnlyMovesTheSequence() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        let builds = rig.publisher.builds
        let target = rig.store.appliedSequence + 7
        rig.store.advanceAppliedSequence(to: target)
        await Self.settle(rig)
        #expect(rig.router.snapshots.current.topology.daemonSequence == target, "a read waiting on the barrier would not wake")
        #expect(rig.publisher.builds == builds, "\(rig.publisher.builds - builds) topology builds for a batch that changed nothing it shows")
        #expect(rig.publisher.sequencePublishes > 0)
    }

    @Test func aModelChangePublishesOnTheNextFrame() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        func title() -> String? { rig.router.snapshots.current.topology.workspaces.first?.panes.first?.tabs.first?.title }
        let builds = rig.publisher.builds
        rig.store.apply(.titleChanged(surface: 1, title: "changed"))
        for _ in 0..<8 { await Task.yield() } // the observation hop that queues the publish
        #expect(rig.publisher.builds == builds, "the change built the snapshot in its own turn")
        rig.work.frameDidFire() // the next display frame
        #expect(title() == "changed", "the change was not published on the next frame")
        #expect(rig.publisher.builds - builds == 1)
        for _ in 0..<8 { await Task.yield() }
        rig.work.frameDidFire()
        #expect(rig.publisher.builds - builds == 1, "the publisher queued another build after publishing (a re-arm)")
    }

    /// A tab title is read by the workspace's cache entry, whose tracking the build's own tracking merged when it
    /// built the entry: both see the change, and it costs one build, not one per tracking.
    @Test func aCachedWorkspaceChangeBuildsOnce() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        for title in ["first", "second"] {
            let builds = rig.publisher.builds
            rig.store.apply(.titleChanged(surface: 1, title: title))
            await Self.settle(rig)
            #expect(rig.router.snapshots.current.topology.workspaces.first?.panes.first?.tabs.first?.title == title,
                    "the title change was not published")
            #expect(rig.publisher.builds - builds == 1, "\(rig.publisher.builds - builds) builds for one title change (want 1)")
        }
    }

    /// A sequence that moves in the batch of a topology change rides on the topology publish: a sequence-only publish
    /// would show the new sequence beside the old topology.
    @Test func aSequenceBeforeATopologyChangeIsNotPublishedBesideTheOldTopology() async {
        let rig = await Self.rig()
        defer { rig.stop() }
        let target = rig.store.appliedSequence + 3
        rig.store.advanceAppliedSequence(to: target)
        rig.store.apply(.disconnected(reason: "after"))
        let sequencePublishes = rig.publisher.sequencePublishes
        await Self.settle(rig)
        let topology = rig.router.snapshots.current.topology
        #expect(topology.daemonState == "disconnected")
        #expect(topology.daemonSequence == target, "the topology publish missed the sequence")
        #expect(rig.publisher.sequencePublishes == sequencePublishes,
                "a sequence-only publish ran while a topology change was pending (new sequence beside the old topology)")
    }
}

@MainActor
private final class SequenceFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
