import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The control snapshot publisher's work per daemon change. Its observations deliver in the automation class of a
/// scheduler with no display link (p04-input-026), so they apply on the next main run loop pass; the control frames
/// are ones the test runs itself:
/// - a daemon batch that changes nothing the topology shows (a busy terminal's activity, a status tick in another
///   workspace) moves the published sequence, so a CLI read waiting on its write barrier still wakes, but maps no
///   topology: each such batch rebuilt it (10 printing terminals in STRESS; perf-lead.md issue 5);
/// - a change the build read publishes once, in the topology observation's automation apply, with no control frame
///   (it took one `Task` hop per change and then asked for a frame; before that it waited for 100 ms after the last
///   publish, asking for a frame on every display frame until then);
/// - a sequence that moves before a topology change in the same turn is not published beside the old topology.
@MainActor @Suite(.serialized)
struct ControlSnapshotSequenceTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// Display frames the test runs: `fire()` runs the work asked for so far, as one frame.
    final class ManualFrames: ControlFrameSource, @unchecked Sendable { // touched on the main actor only
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        nonisolated(unsafe) private(set) var asked = 0 // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            asked += 1
            pending.append(work)
        }
        @MainActor func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
        @MainActor var isEmpty: Bool { pending.isEmpty }
    }

    private struct Rig {
        let services: AppServices
        let router: ControlRouter
        let frames: ManualFrames
        let publisher: ControlSnapshotPublisher
        var store: DaemonStore { services.daemon.store }
    }

    /// One workspace with one tab, a started publisher on manual frames, its first publish done.
    private static func rig() async -> Rig {
        _ = NSApplication.shared
        // No link: an automation apply runs on the next main run loop pass, as in an occluded app.
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
        let frames = ManualFrames()
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: frames)
        publisher.start()
        let rig = Rig(services: services, router: router, frames: frames, publisher: publisher)
        Self.settle(rig) { rig.frames.isEmpty }
        return rig
    }

    /// Runs the main run loop (the observations' automation applies) and, with `firingFrames`, the control frames
    /// asked for, until `done`: at most 5 s.
    private static func settle(_ rig: Rig, firingFrames: Bool = true, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        repeat {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if firingFrames { rig.frames.fire() }
        } while !done() && Date() < end
    }

    private static func daemonState(_ rig: Rig) -> String { rig.router.snapshots.current.topology.daemonState }

    @Test func aBatchThatChangesNoTopologyOnlyMovesTheSequence() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let builds = rig.publisher.builds
        let target = rig.store.appliedSequence + 7
        rig.store.advanceAppliedSequence(to: target)
        Self.settle(rig) { rig.router.snapshots.current.topology.daemonSequence == target }
        #expect(rig.router.snapshots.current.topology.daemonSequence == target, "a read waiting on the barrier would not wake")
        #expect(rig.publisher.builds == builds, "\(rig.publisher.builds - builds) topology builds for a batch that changed nothing it shows")
        #expect(rig.publisher.sequencePublishes > 0)
    }

    /// The connection state is read by the publisher's own build (not a cached workspace entry): its change is the
    /// topology observation's, which publishes in its automation apply, once for the turn's changes, with no frame.
    @Test func anObservedChangePublishesOnceInOneAutomationApplyWithNoFrame() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let builds = rig.publisher.builds
        rig.store.apply(.disconnected("first"))
        rig.store.apply(.disconnected("second"))
        #expect(Self.daemonState(rig) == "connected", "published inside the change")
        Self.settle(rig, firingFrames: false) { Self.daemonState(rig) == "disconnected" }
        #expect(Self.daemonState(rig) == "disconnected", "the change was not published without a control frame")
        #expect(rig.publisher.builds - builds == 1, "\(rig.publisher.builds - builds) builds for two changes in one turn (want 1)")
        var passes = 0
        Self.settle(rig, firingFrames: false) {
            passes += 1
            return passes == 10
        }
        #expect(rig.publisher.builds - builds == 1, "the publisher rebuilt with nothing changed (a re-arm)")
    }

    @Test func aSequenceBeforeATopologyChangeIsNotPublishedBesideTheOldTopology() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
        let target = rig.store.appliedSequence + 3
        // The sequence moves first, then the topology, before either apply runs: the sequence watch's apply runs
        // first and must leave the publish to the topology's (the topology watch counted its change in the will-set).
        rig.store.advanceAppliedSequence(to: target)
        rig.store.apply(.disconnected("after"))
        let sequencePublishes = rig.publisher.sequencePublishes
        Self.settle(rig, firingFrames: false) { Self.daemonState(rig) == "disconnected" }
        #expect(Self.daemonState(rig) == "disconnected")
        #expect(rig.router.snapshots.current.topology.daemonSequence == target, "the topology publish missed the sequence")
        #expect(rig.publisher.sequencePublishes == sequencePublishes,
                "a sequence-only publish ran while a topology change was pending (new sequence beside the old topology)")
    }
}
