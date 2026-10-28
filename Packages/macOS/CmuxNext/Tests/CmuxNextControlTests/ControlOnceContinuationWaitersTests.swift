import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// The control module's waits on CmuxSafeConcurrency's OnceContinuation: each still answers
/// as its raw continuation did, whichever of the producer and the waiter comes first.
@Suite(.timeLimit(.minutes(1))) struct ControlOnceContinuationWaitersTests {
    private static func request(_ key: String) -> ControlIdempotencyCache.Fingerprint {
        .run(ControlActionRequest(actionID: "noop", arguments: ["key": .string(key)]))
    }

    /// Claims `key` twice: the first runs, the second joins it.
    private static func joiner(of key: String, in cache: ControlIdempotencyCache) -> ControlIdempotencyCache.Joiner? {
        guard case .run = cache.claim(key, fingerprint: request(key)) else { return nil }
        guard case .join(let joiner) = cache.claim(key, fingerprint: request(key)) else { return nil }
        return joiner
    }

    @Test func aJoinerGetsTheRunsOutcome() async throws {
        let cache = ControlIdempotencyCache()
        let joiner = try #require(Self.joiner(of: "k", in: cache))
        let joined = Task { await joiner.outcome() }
        cache.finish("k", with: .success(.string("reply")))
        #expect(await joined.value == .success(.string("reply")))
    }

    @Test func aJoinerOfARunThatNeverStartedGetsNil() async throws {
        let cache = ControlIdempotencyCache()
        let joiner = try #require(Self.joiner(of: "k", in: cache))
        let joined = Task { await joiner.outcome() }
        cache.forget("k")
        #expect(await joined.value == nil)
    }

    @Test func aSnapshotWaitPastItsDeadlineAnswersNil() async {
        let store = ControlSnapshotStore()
        let snapshot = await store.snapshot(where: { _ in false }, deadline: .now)
        #expect(snapshot == nil)
    }

    @Test func aCancelledSnapshotWaitAnswersNil() async {
        let store = ControlSnapshotStore()
        let wait = Task { await store.snapshot(where: { _ in false }, deadline: .now + .seconds(30)) }
        wait.cancel()
        #expect(await wait.value == nil)
    }

    @Test func aDeadlineRaceReturnsTheOperationsValue() async throws {
        let value = try await ControlDeadline.shared.run(method: "test.value", deadline: .now + .seconds(30)) { 7 }
        #expect(value == 7)
    }

    @Test func aDeadlineRaceThrowsTimeoutWhenTheOperationIsSlower() async {
        // An operation that answers only when cancelled: the deadline wins and cancels it.
        // The operation holds the stream's continuation, so the stream ends only with the operation's cancellation.
        let (never, source) = AsyncStream<Int>.makeStream()
        do {
            _ = try await ControlDeadline.shared.run(method: "test.slow", deadline: .now + .milliseconds(20)) { [source] in
                defer { source.finish() }
                for await value in never { return value }
                return 0
            }
            Issue.record("the deadline should have won")
        } catch let error as ControlError {
            #expect(error.code == "timeout")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
