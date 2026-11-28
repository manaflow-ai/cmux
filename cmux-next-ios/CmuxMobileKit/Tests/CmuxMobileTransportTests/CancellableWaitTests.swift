import Foundation
import Testing
@testable import CmuxMobileTransport

/// A send queued behind a long one (an earlier prompt's 1-minute 4K video still uploading on
/// LTE) stops at once on Stop, and nothing of it goes on (Leo, 2026-11-24: "i also couldnt
/// cancel out of the send").
@Suite(.timeLimit(.minutes(1))) struct CancellableWaitTests {
    @Test func stopWhileQueuedBehindAnUnfinishedVideoSendStopsAtOnceAndSendsNothing() async throws {
        let earlier = AsyncStream<Void>.makeStream()
        // The earlier send: never finishes during this test, and ignores cancellation, as an
        // `await task.value` on it would.
        let video = Task<Void, Never> { for await _ in earlier.stream {} }
        let sent = SentCounter()
        let queued = Task {
            try await CancellableWait.until(video)
            try Task.checkCancellation()
            sent.increment()
        }
        try await Task.sleep(for: .milliseconds(50))
        let stopped = ContinuousClock.now
        queued.cancel()
        let outcome = await queued.result
        #expect(ContinuousClock.now - stopped < .seconds(2))
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(sent.value == 0)
        // The earlier send is its owner's to stop: still running.
        #expect(!video.isCancelled)
        earlier.continuation.finish()
        await video.value
    }

    @Test func aPreCancelledWaitThrowsWithoutWaiting() async {
        let video = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
        defer { video.cancel() }
        let queued = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await CancellableWait.until(video)
        }
        let outcome = await queued.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test func returnsOnceTheEarlierSendEnds() async throws {
        let video = Task<Void, Never> {}
        try await CancellableWait.until(video)
    }
}

private final class SentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
