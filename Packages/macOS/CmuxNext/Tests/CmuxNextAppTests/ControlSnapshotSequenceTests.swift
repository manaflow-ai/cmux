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

    /// Runs a frame's work on the next main-actor turn (no display link in a test process).
    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
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
}
