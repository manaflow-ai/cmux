import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Compat reads answer from the published `ControlSnapshot` (architecture.md
/// 5a), never from a per-call `list-workspaces`: under the CLI storm that
/// round trip missed the 2 s deadline for ~15% of reads.
@Suite(.timeLimit(.minutes(1))) struct CompatReadBarrierTests {
    /// The service holds its router weakly; the caller keeps both alive.
    func install() -> (ControlRouter, CompatService) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        // No daemon connection: any daemon request fails at once.
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        return (router, service)
    }

    @Test func identifyAnswersFromTheSnapshotWithoutTheDaemon() async throws {
        let (router, _) = install()
        let sample = ControlSnapshot.sample()
        router.snapshots.publish { $0 = sample }
        let identify = try await router.handle(ControlRequest(method: "system.identify")).get()
        // With a daemon round trip the missing connection leaves focus null.
        let focused = try #require(identify["focused"]?.objectValue, "identify asked the daemon: \(identify)")
        #expect(focused["surface_ref"] != nil || focused["surface_id"] != nil, "\(focused)")
        let tree = try await router.handle(ControlRequest(method: "system.tree")).get()
        #expect(tree["windows"]?.arrayValue?.isEmpty == false)
    }
    /// A write raised the barrier past the published topology: the read
    /// waits for the publish that reflects it and sees the write.
    @Test func aReadAfterAWriteWaitsForTheWritesEvents() async throws {
        let (router, service) = install()
        var stale = ControlSnapshot.sample()
        stale.topology.daemonSequence = 4
        router.snapshots.publish { $0 = stale }
        service.writes.raise(to: 9)
        let read = Task { try await router.handle(ControlRequest(method: "workspace.list")).get() }
        // Deterministic hand-off: publish only once the read is parked.
        while !router.snapshots.hasWaiters { await Task.yield() }
        var fresh = stale
        fresh.topology.daemonSequence = 9
        fresh.topology.workspaces.append(ControlWorkspaceInfo(id: "ws-2", handle: "7", name: "Created",
                                                              screens: [ControlScreenInfo(id: "screen-2", handle: "8")]))
        router.snapshots.publish { $0 = fresh }
        let listed = try await read.value
        let names = listed["workspaces"]?.arrayValue?.compactMap { $0["title"]?.stringValue ?? $0["name"]?.stringValue } ?? []
        #expect(names.contains("Created"), "\(listed)")
    }

    /// A snapshot already past the barrier answers at once; no waiter.
    @Test func aReadWithNoPendingWriteDoesNotWait() async throws {
        let (router, service) = install()
        var sample = ControlSnapshot.sample()
        sample.topology.daemonSequence = 12
        router.snapshots.publish { $0 = sample }
        service.writes.raise(to: 12)
        let started = ContinuousClock.now
        _ = try await router.handle(ControlRequest(method: "system.identify")).get()
        _ = try await router.handle(ControlRequest(method: "workspace.list")).get()
        #expect(ContinuousClock.now - started < .milliseconds(200))
        #expect(!router.snapshots.hasWaiters)
    }

    /// A store that never catches up (resync failed) costs at most the
    /// barrier wait, then the read answers from the snapshot it has.
    @Test func anUnreachedBarrierIsBounded() async throws {
        let (router, service) = install()
        router.snapshots.publish { $0 = ControlSnapshot.sample() }
        service.writes.raise(to: 1 << 50)
        let started = ContinuousClock.now
        // Snapshot-lane reads answer from what they have.
        let windows = try await router.handle(ControlRequest(method: "window.list")).get()
        #expect(windows["windows"]?.arrayValue?.count == 1)
        #expect(ContinuousClock.now - started < CompatService.barrierWait + .milliseconds(500))
        // Verbs fall back to the daemon, here missing: a typed error, still bounded.
        let second = ContinuousClock.now
        guard case .failure(let error) = await router.handle(ControlRequest(method: "workspace.list")) else {
            Issue.record("expected the daemon fallback to fail without a connection")
            return
        }
        #expect(error.code == "unavailable")
        #expect(ContinuousClock.now - second < CompatService.barrierWait + .milliseconds(500))
        #expect(!router.snapshots.hasWaiters)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ControlSnapshotWaiterTests {
    @Test func waiterResumesOnTheFirstPublishThatReflectsItsSequence() async {
        let store = ControlSnapshotStore()
        let waiter = Task { await store.snapshot(reflecting: 3, deadline: .now + .seconds(30)) }
        while !store.hasWaiters { await Task.yield() }
        store.publish { $0.topology.isLoaded = true; $0.topology.daemonSequence = 2 }
        #expect(store.hasWaiters)
        store.publish { $0.topology.daemonSequence = 3 }
        #expect(await waiter.value?.topology.daemonSequence == 3)
        #expect(!store.hasWaiters)
    }

    @Test func waiterGivesUpAtItsDeadlineAndOnCancellation() async {
        let store = ControlSnapshotStore()
        #expect(await store.snapshot(reflecting: 1, deadline: .now + .milliseconds(50)) == nil)
        let cancelled = Task { await store.snapshot(reflecting: 1, deadline: .now + .seconds(30)) }
        while !store.hasWaiters { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(!store.hasWaiters)
    }
}
