import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A daemon batch that changes nothing the control topology shows (a busy terminal's activity, a
/// status tick in another workspace) moves the published sequence, so a CLI read waiting on its write
/// barrier still wakes, but maps no topology: each such batch rebuilt it (at most every 100 ms, with
/// 10 printing terminals in STRESS; perf-lead.md issue 5, the main thread under load).
@MainActor @Suite(.serialized)
struct ControlSnapshotSequenceTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// Runs a frame's work on the next main-actor turn (no display link in a test process), and counts the
    /// frames asked for.
    final class SoonFrames: ControlFrameSource, @unchecked Sendable { // `asked` is touched on the main actor only
        nonisolated(unsafe) var asked = 0 // main actor only (scheduleFrame is called there)
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            asked += 1
            Task { @MainActor in work() }
        }
    }

    /// The topology builds `DebugTimings` recorded since the last clear.
    private static func builds() -> Int {
        guard case .object(let report) = DebugTimings.handle([:]), case .array(let publishes)? = report["control_publishes"] else { return -1 }
        return publishes.count
    }

    @Test func aBatchThatChangesNoTopologyOnlyMovesTheSequence() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
        publisher.start()
        defer { publisher.stop() }
        let store = services.daemon.store
        _ = DebugTimings.handle(["clear": .bool(true)])

        let target = store.appliedSequence + 7
        store.advanceAppliedSequence(to: target)
        let deadline = ContinuousClock.now + .seconds(2)
        while router.snapshots.current.topology.daemonSequence < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test harness: the publish lands on a later turn
        }
        // Past the publisher's 100 ms model-change interval: a rebuild would have run by now.
        try await Task.sleep(for: .milliseconds(250))

        #expect(router.snapshots.current.topology.daemonSequence == target, "a read waiting on the barrier would not wake")
        #expect(Self.builds() == 0, "\(Self.builds()) topology builds for a batch that changed nothing the topology shows")
    }

    /// A model change (a title, a status tick) publishes on the next display frame, one frame asked for: it waited
    /// for a 100 ms interval after the last publish (`modelChangeInterval`), asking for a frame on every display
    /// frame until then, so a CLI read and the sidebar's control facts lagged up to 100 ms and the wait itself
    /// woke the main thread each frame.
    @Test func aModelChangePublishesOnTheNextFrame() async throws {
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
        let frames = SoonFrames()
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: frames)
        publisher.start()
        defer { publisher.stop() }
        func title() -> String? { router.snapshots.current.topology.workspaces.first?.panes.first?.tabs.first?.title }

        let asked = frames.asked
        let start = ContinuousClock.now
        store.apply(.titleChanged(surface: 1, title: "changed"))
        while title() != "changed", ContinuousClock.now - start < .seconds(2) {
            await Task.yield() // test harness: the publish lands on a later main-actor turn
        }
        let waited = ContinuousClock.now - start
        #expect(title() == "changed", "the change never reached the published topology")
        #expect(waited < .milliseconds(50), "the change took \(waited) to publish (want the next frame, not an interval)")
        #expect(frames.asked - asked <= 1, "\(frames.asked - asked) frames asked for one change (want 1, no re-arm)")
    }
}
