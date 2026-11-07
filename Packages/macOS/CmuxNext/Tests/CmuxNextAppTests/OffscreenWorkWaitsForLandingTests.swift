import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextLayout
import CmuxNextWakeups
import Foundation
import Testing

/// Leo, 2026-11-04: interaction cost stays constant, "the visible window comes first, and off-screen work is deferred".
/// A Reopen Closed under load showed main-thread work nothing on screen needs landing mid-slide: the control snapshot's
/// build (77-85 ms) and the parked New Tab page's prepare (50-75 ms, its omnibar build). Each waits for the motion to
/// land, once, and runs then.
@MainActor @Suite(.serialized)
struct OffscreenWorkWaitsForLandingTests {
    /// A layout whose motion the test starts and lands; the work waiting for the landing, by key (a later call replaces).
    @MainActor final class Layout: LayoutStillness {
        var isInLayoutMotion = false
        var waiting: [String: @MainActor () -> Void] = [:]
        func whenStill(_ key: String, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void) { waiting[key] = work }
        func land() {
            isInLayoutMotion = false
            let ready = waiting
            waiting.removeAll()
            ready.values.forEach { $0() }
        }
    }

    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    @Test func aSnapshotPublishDuringAMotionWaitsForItsLandingAndRunsOnce() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames(), notifications: NotificationCenter())
        let layout = Layout()
        publisher.layouts = { [layout] }
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds

        layout.isInLayoutMotion = true
        for _ in 0..<5 {
            publisher.invalidate()
            for _ in 0..<4 { await Task.yield() }
        }
        #expect(publisher.builds == builds, "\(publisher.builds - builds) snapshot builds in the motion's frames (want 0)")
        #expect(layout.waiting.keys.sorted() == ["ControlSnapshotPublisher.publish"], "waiting: \(layout.waiting.keys.sorted())")
        #expect(router.snapshots.isStale, "a read in the motion would get the snapshot from before it")

        layout.land()
        #expect(publisher.builds == builds + 1, "\(publisher.builds - builds) builds at the landing (want 1)")
        #expect(!router.snapshots.isStale)

        // At rest a change publishes on its frame, as before.
        publisher.invalidate()
        for _ in 0..<8 { await Task.yield() }
        #expect(publisher.builds == builds + 2)
        #expect(layout.waiting.isEmpty)
    }

    @Test func aReadDuringAMotionStillBuildsTheSnapshot() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames(), notifications: NotificationCenter())
        let layout = Layout()
        publisher.layouts = { [layout] }
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds

        layout.isInLayoutMotion = true
        publisher.invalidate()
        for _ in 0..<4 { await Task.yield() }
        let reply = await router.handle(ControlRequest(method: "system.ping"))
        #expect((try? reply.get()) != nil)
        #expect(publisher.builds == builds + 1, "\(publisher.builds - builds) builds for a read in the motion (want 1)")
        // The landing finds it fresh: no second build.
        layout.land()
        #expect(publisher.builds == builds + 1)
    }

    /// A barrier read (an action's settle, `after: "sync"`) that arrives after the publish was put off gets the snapshot
    /// built for it in the motion, not at the landing: a long divider drag would time it out.
    @Test func aBarrierReadAfterADeferredPublishIsServedDuringTheMotion() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames(), notifications: NotificationCenter())
        let layout = Layout()
        publisher.layouts = { [layout] }
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds
        let generation = router.snapshots.current.generation

        layout.isInLayoutMotion = true
        publisher.invalidate()
        for _ in 0..<4 { await Task.yield() }
        #expect(publisher.builds == builds && router.snapshots.isStale, "the publish was not put off")
        let served = await router.snapshots.snapshot(where: { $0.generation > generation }, deadline: .now + .seconds(5))
        #expect(served != nil, "the barrier read waited for the landing")
        #expect(publisher.builds == builds + 1, "\(publisher.builds - builds) builds for the barrier read (want 1)")
        #expect(layout.isInLayoutMotion, "the motion ended before the read was served")
    }

    @Test func theNewTabSparesWarmDuringAMotionWaitsForItsLanding() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let pool = services.newTabSpares
        let layout = Layout()
        pool.targetLayout = { layout }
        var made = 0
        pool.makeSpare = { _ in made += 1; return nil }
        defer { pool.makeSpare = nil }

        layout.isInLayoutMotion = true
        pool.warmNow()
        pool.warmNow()
        #expect(made == 0, "a spare was made in the motion's frames")
        #expect(layout.waiting.keys.sorted() == ["NewTabSparePool.warm"], "waiting: \(layout.waiting.keys.sorted())")
        layout.land()
        #expect(layout.waiting.isEmpty, "the landing left work waiting: \(layout.waiting.keys.sorted())")
    }
}
