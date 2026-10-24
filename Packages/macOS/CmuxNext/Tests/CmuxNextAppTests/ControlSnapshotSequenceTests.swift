import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The control snapshot publisher's work per daemon change, with display frames the test runs itself (no display
/// link in a test process, no clock, no wait for time to pass):
/// - a daemon batch that changes nothing the topology shows (a busy terminal's activity, a status tick in another
///   workspace) moves the published sequence, so a CLI read waiting on its write barrier still wakes, but maps no
///   topology: each such batch rebuilt it (10 printing terminals in STRESS; perf-lead.md issue 5);
/// - a model change publishes on the next frame with one frame asked for: it waited for 100 ms after the last
///   publish (`modelChangeInterval`), asking for a frame on every display frame until then.
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
        let services = AppServices(environment: AppEnvironment.current([:]))
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
        await Self.settle(rig)
        return rig
    }

    /// Runs the main-actor work the change queued (observation hops) and the frames it asked for, until both are
    /// done: a bounded number of turns, never a wait for time.
    private static func settle(_ rig: Rig) async {
        for _ in 0..<50 {
            for _ in 0..<8 { await Task.yield() }
            if rig.frames.isEmpty { return }
            rig.frames.fire()
        }
    }

    @Test func aBatchThatChangesNoTopologyOnlyMovesTheSequence() async {
        let rig = await Self.rig()
        defer { rig.publisher.stop() }
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
        defer { rig.publisher.stop() }
        func title() -> String? { rig.router.snapshots.current.topology.workspaces.first?.panes.first?.tabs.first?.title }
        let asked = rig.frames.asked
        rig.store.apply(.titleChanged(surface: 1, title: "changed"))
        for _ in 0..<8 { await Task.yield() } // the observation hop that asks for the frame
        #expect(rig.frames.asked - asked == 1, "\(rig.frames.asked - asked) frames asked for one change (want 1)")
        rig.frames.fire() // the next display frame
        #expect(title() == "changed", "the change was not published on the next frame")
        for _ in 0..<8 { await Task.yield() }
        #expect(rig.frames.isEmpty, "the publisher asked for another frame after publishing (a re-arm)")
        #expect(rig.frames.asked - asked == 1)
    }
}
