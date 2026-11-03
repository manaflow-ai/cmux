import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import Foundation
import Observation
import Testing

/// cmuxterm-hq#6338, stack 2: on the launch after every nightly update the restore's first registry write
/// (`WindowManager.restore`, the launch snapshot's membership cleared) held the main thread 2.4-2.6 s, all of it in
/// Observation cancelling trackers. Nothing the control snapshot reads changes until that restore, and every CLI read of
/// a stale snapshot built it under a new `withObservationTracking` while the last one was still armed, so one tracking
/// per CLI call piled up on every value the build reads (the registry's membership among them) and the first write
/// cancelled them all. And the launch membership was one observed dictionary: a write of one window's entry woke the
/// readers of every window.
@MainActor @Suite(.serialized)
struct LaunchRestoreTrackerPileTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    nonisolated final class Flag: @unchecked Sendable {
        var fired = false
    }

    /// A reader of one window's launch membership hears only that window's entry: another window's entry made or
    /// cleared notifies it of nothing.
    @Test func aWindowsLaunchMembershipReaderIgnoresOtherWindows() {
        let registry = WindowRegistryStore()
        registry.provisional["a"] = ["k1"]
        registry.provisional["b"] = ["k2"]
        let flag = Flag()
        let members = withObservationTracking { registry.members(of: "b") } onChange: { flag.fired = true }
        #expect(members == ["k2"])
        registry.provisional["a"] = ["k1", "k3"]
        registry.provisional["a"] = nil
        #expect(!flag.fired, "a write of window a's launch membership notified a reader of window b's")
        registry.provisional["b"] = ["k2"]
        #expect(!flag.fired, "an unchanged write of window b's launch membership notified its reader")
        registry.provisional["b"] = nil
        #expect(flag.fired, "clearing window b's launch membership did not notify its reader")
    }

    /// 20,000 CLI calls before the restore (a write, then a read of the stale snapshot, as agents' hooks make while the
    /// daemon starts): the restore's clear of the launch membership stays under 20 ms (the head takes 0.05 ms; the base's cost grows with the calls, 27 ms at 5,000 with this one-window fixture and seconds in the app, whose build reads far more). On the base each read armed
    /// one more tracking of the whole build, and the clear cancelled every one.
    @Test func cliCallsBeforeTheRestoreLeaveTheRestoresClearCheap() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.windows.registry.provisional["pile-window"] = ["k1"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "pile-window"))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames(), notifications: NotificationCenter())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds

        let calls = 20_000
        for _ in 0..<calls {
            try await router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
            _ = await router.handle(ControlRequest(method: "system.ping"))
        }
        try #require(publisher.builds - builds >= calls / 2, "\(publisher.builds - builds) builds for \(calls) CLI calls: the fixture does not build per read")

        let started = ContinuousClock.now
        services.windows.registry.provisional["pile-window"] = nil
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("restore clear after \(calls) CLI calls: \(String(format: "%.2f", ms)) ms (\(publisher.builds - builds) builds)")
        #expect(elapsed < .milliseconds(20), "the restore's clear took \(String(format: "%.2f", ms)) ms after \(calls) CLI calls (want < 20 ms)")
    }
}
