import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A control work-queue frame (a script's CLI calls, 1000 a second under load) marks the control snapshot stale
/// instead of building it: each drained frame mapped the topology and walked every mounted pane on the main thread,
/// a full publish every display frame while a script ran. The snapshot is built when a read needs it, once for
/// any number of frames before that read, and still covers the writes those frames made (read-your-writes).
@MainActor @Suite(.serialized)
struct ControlSnapshotLazyPublishTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// Runs each frame's work on the next main-actor turn (no display link in a test process).
    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    @Test func workQueueFramesWithNoReaderBuildNothingAndOneReadBuildsOnce() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        let builds = publisher.builds

        for _ in 0..<100 {
            try await router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        }
        for _ in 0..<8 { await Task.yield() }
        #expect(publisher.builds == builds, "\(publisher.builds - builds) snapshot builds for 100 work-queue frames with no reader (want 0)")

        // One read of main-actor state: the snapshot is built for it, once.
        let reply = await router.handle(ControlRequest(method: "system.identify"))
        #expect((try? reply.get()) != nil)
        #expect(publisher.builds == builds + 1, "\(publisher.builds - builds) builds for one read after the frames (want 1)")
        // A second read with nothing changed builds nothing.
        _ = await router.handle(ControlRequest(method: "system.identify"))
        #expect(publisher.builds == builds + 1)
    }

    /// A reader that reads no main-actor state never waits on a stale store, and one that does waits only until its
    /// deadline, while the main actor is held (a long main-thread body): before, every request awaited the stale
    /// store's main-actor build before its deadline even began, so one hang blocked every connection.
    @Test func aBlockedMainNeverHoldsAPingAndAReadEndsAtItsDeadline() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .milliseconds(300)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        try await router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}  // marks the store stale
        #expect(router.snapshots.isStale)

        let hold = Duration.milliseconds(1500)
        let held = Task { @MainActor in
            let end = ContinuousClock.now + hold
            while ContinuousClock.now < end {}  // test harness: the main actor held, as a long main-thread body holds it
        }
        let (ping, read) = await Task.detached {
            let start = ContinuousClock.now
            let pong = await router.handle(ControlRequest(method: "system.ping"))
            let pinged = ContinuousClock.now - start
            let readStart = ContinuousClock.now
            let identified = await router.handle(ControlRequest(method: "system.identify"))
            return ((pong, pinged), (identified, ContinuousClock.now - readStart))
        }.value
        await held.value
        #expect((try? ping.0.get()) != nil, "system.ping failed while main was held")
        #expect(ping.1 < .milliseconds(500), "system.ping waited \(ping.1) for a held main actor")
        if case .failure(let error) = read.0 { #expect(error.code == "timeout", "the read failed with \(error.code)") }
        else { Issue.record("a read of main-actor state answered while main was held and the store stale") }
        #expect(read.1 < .milliseconds(1000), "the read waited \(read.1), past its 300 ms deadline")
    }

    /// A frame marks the store stale, the daemon's batch moves the sequence with no waiter yet, then a barrier read
    /// arrives: it returns without waiting for its deadline (the stale store skipped the sequence-only publish, and
    /// nothing asked for a build).
    @Test func aBarrierReadAfterAFrameAndASequenceMoveNeedsNoDeadline() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
        publisher.start()
        defer { publisher.stop() }
        for _ in 0..<8 { await Task.yield() }
        try await router.workQueue.run(method: "test.write", deadline: .now + .seconds(10)) {}
        let target = services.daemon.store.appliedSequence + 3
        services.daemon.store.advanceAppliedSequence(to: target)
        for _ in 0..<8 { await Task.yield() }
        let start = ContinuousClock.now
        let snapshot = await router.snapshots.snapshot(reflecting: target, deadline: .now + .seconds(10))
        let waited = ContinuousClock.now - start
        #expect(snapshot?.topology.daemonSequence == target, "the barrier read never got its sequence")
        #expect(waited < .seconds(2), "the barrier read waited \(waited) (want no deadline wait)")
    }
}
