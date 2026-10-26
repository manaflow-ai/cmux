import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The control snapshot publisher's work per daemon change (p04-input-026). Its publishes run in the automation class
/// of a scheduler with no display link, so they run on the next main run loop pass (``drainMainTurns(rounds:)``):
/// - a daemon batch that changes nothing the topology shows (a busy terminal's activity, a status tick in another
///   workspace) moves the published sequence, so a CLI read waiting on its write barrier still wakes, but maps no
///   topology: each such batch rebuilt it (10 printing terminals in STRESS; perf-lead.md issue 5);
/// - a change the build read, or a cached workspace's change, builds once, with no display frame: the build's own
///   tracking and the cache entry's tracking see the same change and share one dirty bit;
/// - a sequence that moves in the batch of a topology change is never published beside the old topology, also when
///   an explicit publish ran between two such batches.
@MainActor @Suite(.serialized)
struct ControlSnapshotSequenceTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    private struct Rig {
        let services: AppServices
        let router: ControlRouter
        let publisher: ControlSnapshotPublisher
        var store: DaemonStore { services.daemon.store }
        var topology: ControlTopology { router.snapshots.current.topology }
        var title: String? { topology.workspaces.first?.panes.first?.tabs.first?.title }
    }

    /// One workspace with one tab, a started publisher, its first publish done.
    private static func rig() async -> Rig {
        _ = NSApplication.shared
        // No link: an automation post runs on the next main run loop pass, as in an occluded app.
        let services = AppServices(environment: AppEnvironment.current([:]),
                                   mainWork: MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil })
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
        await drainMainTurns()
        return Rig(services: services, router: router, publisher: publisher)
    }

    @Test func aBatchThatChangesNoTopologyOnlyMovesTheSequence() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let builds = rig.publisher.builds, sequencePublishes = rig.publisher.sequencePublishes
        let target = rig.store.appliedSequence + 7
        rig.store.advanceAppliedSequence(to: target)
        await drainMainTurns()
        #expect(rig.topology.daemonSequence == target, "a read waiting on the barrier would not wake")
        #expect(rig.publisher.builds == builds, "\(rig.publisher.builds - builds) topology builds for a batch that changed nothing it shows")
        #expect(rig.publisher.sequencePublishes - sequencePublishes == 1)
    }

    /// The connection state is read by the publisher's own build: two changes in one turn build once, in one
    /// automation post, and no change after it builds again.
    @Test func anObservedChangeBuildsOnceWithNoFrame() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let builds = rig.publisher.builds
        rig.store.apply(.disconnected("first"))
        rig.store.apply(.disconnected("second"))
        #expect(rig.publisher.builds == builds, "the change built inside its will-set")
        #expect(rig.topology.daemonState == "connected")
        await drainMainTurns()
        #expect(rig.topology.daemonState == "disconnected", "the change was not published with no display frame")
        #expect(rig.publisher.builds - builds == 1, "\(rig.publisher.builds - builds) builds for two changes in one turn (want 1)")
        await drainMainTurns()
        #expect(rig.publisher.builds - builds == 1, "the publisher built again with nothing changed (a re-arm)")
    }

    /// A tab title is read by the workspace's cache entry, whose tracking the build's own tracking merged when it
    /// built the entry: both see the change, and it costs one build, not one per tracking.
    @Test func aCachedWorkspaceChangeBuildsOnce() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        for title in ["first", "second"] {
            let builds = rig.publisher.builds
            rig.store.apply(.titleChanged(surface: 1, title: title))
            await drainMainTurns()
            #expect(rig.title == title, "the title change was not published")
            #expect(rig.publisher.builds - builds == 1, "\(rig.publisher.builds - builds) builds for one title change (want 1)")
        }
    }

    @Test func aSequenceBeforeATopologyChangeIsNotPublishedBesideTheOldTopology() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let target = rig.store.appliedSequence + 3
        // The sequence moves first, then the topology, before either apply runs.
        rig.store.advanceAppliedSequence(to: target)
        rig.store.apply(.disconnected("after"))
        let sequencePublishes = rig.publisher.sequencePublishes
        await drainMainTurns()
        #expect(rig.topology.daemonState == "disconnected")
        #expect(rig.topology.daemonSequence == target, "the topology publish missed the sequence")
        #expect(rig.publisher.sequencePublishes == sequencePublishes,
                "a sequence-only publish ran while a topology change was pending (new sequence beside the old topology)")
    }

    /// An explicit publish (a compat intent, a control frame with a waiting read) between two batches ends the first
    /// batch's dirty period, and the second batch's topology change starts a new one: its sequence is not published
    /// beside a topology without it.
    @Test func anExplicitPublishBetweenBatchesKeepsTheNextBatchsTopologyPending() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let builds = rig.publisher.builds, sequencePublishes = rig.publisher.sequencePublishes
        rig.store.advanceAppliedSequence(to: rig.store.appliedSequence + 1)
        rig.store.apply(.titleChanged(surface: 1, title: "batch 1"))
        rig.publisher.publishNow()
        #expect(rig.title == "batch 1")
        let target = rig.store.appliedSequence + 1
        rig.store.apply(.disconnected("batch 2"))
        rig.store.advanceAppliedSequence(to: target)
        await drainMainTurns()
        #expect(rig.topology.daemonState == "disconnected", "the second batch's topology change was not published")
        #expect(rig.topology.daemonSequence == target)
        #expect(rig.publisher.sequencePublishes == sequencePublishes,
                "a sequence-only publish ran before the second batch's topology publish")
        #expect(rig.publisher.builds - builds == 2, "\(rig.publisher.builds - builds) builds (want 2: the explicit one and batch 2's)")
    }
}
