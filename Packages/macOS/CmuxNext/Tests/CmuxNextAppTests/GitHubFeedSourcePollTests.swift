@testable import CmuxNextFeed
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The GitHub poll is a self-rescheduling DemandTimer on the injected clock (p14-energy-019c): a
/// refresh at start, the next one an interval after each ends, a restart on a new interval, and a
/// stop that also stops the refresh that is running.
@MainActor
@Suite struct GitHubFeedSourcePollTests {
    /// Answers notification `n` (ETag `n-<n>`) to the n-th call, records each call's ETag, and
    /// holds a call while the test asks it to.
    private actor Script {
        private(set) var notificationETags: [String?] = []
        private var holding = false
        private var gate: CheckedContinuation<Void, Never>?
        private let started: AsyncStream<Int>.Continuation

        init(started: AsyncStream<Int>.Continuation) { self.started = started }

        func hold() { holding = true }

        func release() {
            holding = false
            gate?.resume()
            gate = nil
        }

        func notifications(etag: String?) async -> GitHubAPIResponse<[GitHubNotification]> {
            notificationETags.append(etag)
            let call = notificationETags.count
            started.yield(call)
            if holding { await withCheckedContinuation { gate = $0 } }
            let notification = GitHubNotification(
                id: "\(call)", reason: "mention", subject: .init(title: "Call \(call)"),
                repository: .init(fullName: "acme/app"), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            return GitHubAPIResponse(value: [notification], etag: "n-\(call)")
        }
    }

    nonisolated private struct Client: GitHubFeedAPI {
        let script: Script
        func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> {
            await script.notifications(etag: etag)
        }
        func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            GitHubAPIResponse(value: [])
        }
    }

    @MainActor private final class Owner: FeedPostingSource {
        var posted: [String] = []
        func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {}
        func send(_ intent: FeedIntent) {}
        func stop() {}
        func post(_ item: FeedItem) { posted.append(item.dedupeKey ?? item.id) }
    }

    @MainActor private final class Rig {
        let clock: ManualClock
        let owner: Owner
        let script: Script
        let calls: AsyncStream<Int>
        let source: GitHubFeedSource

        init() {
            let (calls, started) = AsyncStream.makeStream(of: Int.self)
            let clock = ManualClock()
            let owner = Owner()
            let script = Script(started: started)
            self.clock = clock
            self.owner = owner
            self.script = script
            self.calls = calls
            source = GitHubFeedSource(owner: owner, client: Client(script: script), interval: .seconds(120), clock: clock)
        }

        /// Waits for the next call to start and returns its number.
        func nextCall() async -> Int? {
            for await call in calls { return call }
            return nil
        }
    }

    @Test(.timeLimit(.minutes(1))) func itRefreshesAtStartThenOncePerIntervalAndRestartsOnANewInterval() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        try await rig.clock.waitForSleeper()
        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.clock.sleepRequests.last?.deadline.offset == .seconds(120))
        #expect(rig.clock.sleepRequests.last?.tolerance == WakeLeeway.window(delay: .seconds(120)).tolerance)

        rig.clock.advance(by: .seconds(120))
        #expect(await rig.nextCall() == 2)
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleepRequests.last?.deadline.offset == .seconds(240))
        #expect(await rig.script.notificationETags == [nil, "n-1"])

        // A new interval restarts the poll: one refresh now, the next one 30 s after it.
        rig.source.setInterval(.seconds(30))
        #expect(rig.clock.sleeperCount == 0)
        #expect(await rig.nextCall() == 3)
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleepRequests.last?.deadline.offset == .seconds(150))

        rig.source.stop()
        #expect(rig.clock.sleeperCount == 0)
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:2", "github:notification:3"])
    }

    /// A stop (GitHub turned off, sign-out, disconnect) during a timer-fired refresh: the refresh
    /// posts nothing and writes no ETag over the reset, so the next start asks without one.
    @Test(.timeLimit(.minutes(1))) func aStopDuringATimerRefreshDropsItsResults() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        try await rig.clock.waitForSleeper()

        await rig.script.hold()
        rig.clock.advance(by: .seconds(120))
        #expect(await rig.nextCall() == 2)
        let stopped = try #require(rig.source.runner)
        rig.source.stop()
        rig.source.resetConditionalRequests()
        await rig.script.release()
        await stopped.value

        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.source.githubDetails.isEmpty)
        #expect(rig.clock.sleeperCount == 0)

        rig.source.start()
        #expect(await rig.nextCall() == 3)
        #expect(await rig.script.notificationETags == [nil, "n-1", nil])
        try await rig.clock.waitForSleeper()
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:3"])
        rig.source.stop()
    }
}
