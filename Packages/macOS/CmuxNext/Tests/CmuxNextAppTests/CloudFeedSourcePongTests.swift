@testable import CmuxNextFeed
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The feed socket's liveness probe is a DemandTimer on the injected clock: no
/// pong within ``CloudFeedSource/pongLimit`` closes the socket, a pong first drops the deadline.
@MainActor
@Suite struct CloudFeedSourcePongTests {
    private func source(_ clock: ManualClock) -> CloudFeedSource {
        CloudFeedSource(apiBaseURL: URL(string: "https://api.test")!, device: "Mac", mainWork: linklessMainWork(), token: { "t" },
                        reconnect: Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0),
                        connect: nil, clock: clock)
    }

    /// The closes so far, once the test ends the stream (every close an answer makes is synchronous).
    private func count(_ closes: AsyncStream<Void>, ending closed: AsyncStream<Void>.Continuation) async -> Int {
        closed.finish()
        var count = 0
        for await _ in closes { count += 1 }
        return count
    }

    @Test(.timeLimit(.minutes(1))) func noPongWithinTheLimitClosesTheSocket() async throws {
        let clock = ManualClock()
        let source = source(clock)
        let (closes, closed) = AsyncStream.makeStream(of: Void.self)
        _ = source.armPongLimit { closed.yield() }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == CloudFeedSource.pongLimit)
        #expect(clock.sleepRequests.last?.tolerance == WakeLeeway.window(delay: CloudFeedSource.pongLimit).tolerance)
        clock.advance(by: CloudFeedSource.pongLimit - .milliseconds(1))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .milliseconds(1))
        for await _ in closes { break }
    }

    @Test(.timeLimit(.minutes(1))) func aPongFirstDropsTheDeadline() async throws {
        let clock = ManualClock()
        let source = source(clock)
        let (closes, closed) = AsyncStream.makeStream(of: Void.self)
        let answer = source.armPongLimit { closed.yield() }
        try await clock.waitForSleeper()
        answer(false)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: CloudFeedSource.pongLimit)
        #expect(await count(closes, ending: closed) == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedPingClosesAtOnceAndAnOlderPongKeepsTheNewerDeadline() async throws {
        let clock = ManualClock()
        let source = source(clock)
        let (closes, closed) = AsyncStream.makeStream(of: Void.self)
        let older = source.armPongLimit { closed.yield() }
        try await clock.waitForSleeper()
        let newer = source.armPongLimit { closed.yield() }
        try await clock.waitForSleeper()
        older(false)
        #expect(clock.sleeperCount == 1)
        newer(true)
        #expect(await count(closes, ending: closed) == 1)
    }

    @Test(.timeLimit(.minutes(1))) func stopDropsThePendingDeadlineAndTheAnswer() async throws {
        let clock = ManualClock()
        let source = source(clock)
        let (closes, closed) = AsyncStream.makeStream(of: Void.self)
        let answer = source.armPongLimit { closed.yield() }
        try await clock.waitForSleeper()
        source.stop()
        #expect(clock.sleeperCount == 0)
        answer(true)
        #expect(await count(closes, ending: closed) == 0)
    }
}
