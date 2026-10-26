@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// The control module's parked waiters on `OnceContinuation` (p10-stability-087): an idempotency
/// joiner gets its run's outcome (or nil when the run never started), and a snapshot reader wakes on
/// the publish it waits for, at its deadline, or on cancellation.
@Suite struct ControlOnceContinuationWaitersTests {
    private static let request = ControlIdempotencyCache.Fingerprint.run(ControlActionRequest(actionID: "pane.focus"))

    @Test func aJoinerGetsTheOutcomeOfTheRunItJoined() async throws {
        let cache = ControlIdempotencyCache()
        guard case .run = cache.claim("k", fingerprint: Self.request) else { Issue.record("first claim must run"); return }
        guard case .join(let joiner) = cache.claim("k", fingerprint: Self.request) else {
            Issue.record("a retry while the run settles must join it")
            return
        }
        let joined = Task { await joiner.outcome() }
        await Task.yield()
        cache.finish("k", with: .success(.string("done")))
        let outcome = try #require(await joined.value)
        #expect(try outcome.get() == .string("done"))
        // A second finish of the same key changes nothing and wakes nobody twice.
        cache.finish("k", with: .success(.string("again")))
        guard case .finished(let stored) = cache.claim("k", fingerprint: Self.request) else {
            Issue.record("the finished run must replay")
            return
        }
        #expect(try stored.get() == .string("done"))
    }

    @Test func aJoinerOfARunThatNeverStartedGetsNil() async {
        let cache = ControlIdempotencyCache()
        _ = cache.claim("k", fingerprint: Self.request)
        guard case .join(let joiner) = cache.claim("k", fingerprint: Self.request) else {
            Issue.record("a retry while the run settles must join it")
            return
        }
        let joined = Task { await joiner.outcome() }
        await Task.yield()
        cache.forget("k")
        #expect(await joined.value == nil)
    }

    @Test func aSnapshotReaderWakesOnTheReadyPublish() async {
        let store = ControlSnapshotStore()
        let deadline = ContinuousClock.now + .seconds(30)
        let read = Task { await store.snapshot(where: { $0.settings != nil }, deadline: deadline) }
        while !store.hasWaiters { await Task.yield() }
        store.publish { $0.settings = .string("loaded") }
        let snapshot = await read.value
        #expect(snapshot?.settings == .string("loaded"))
        #expect(!store.hasWaiters)
    }

    @Test func aSnapshotReaderEndsAtItsDeadline() async {
        let store = ControlSnapshotStore()
        let snapshot = await store.snapshot(where: { _ in false }, deadline: ContinuousClock.now + .milliseconds(20))
        #expect(snapshot == nil)
        #expect(!store.hasWaiters)
    }

    @Test func aCancelledSnapshotReaderEndsWithNil() async {
        let store = ControlSnapshotStore()
        let read = Task { await store.snapshot(where: { _ in false }, deadline: ContinuousClock.now + .seconds(30)) }
        while !store.hasWaiters { await Task.yield() }
        read.cancel()
        #expect(await read.value == nil)
        #expect(!store.hasWaiters)
    }
}
