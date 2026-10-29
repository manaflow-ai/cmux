import CmuxNextHomeEngine
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import os
import Testing

/// The model router lease waits on one one-shot DemandTimer per pass. The renewal is a flexible
/// deadline 90 s before the token's expiry that may come early but never late; a retry after a failure is never early.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ModelRouterLeaseTests {
    @Test func theRenewalWakeAndItsPolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hour = ModelRouterLease.renewal(expiresAt: 1_003_600, now: now)
        #expect(hour.wake == .renewal(after: .seconds(3510)))
        #expect(!hour.forceRefresh)
        let soon = ModelRouterLease.renewal(expiresAt: 1_000_120, now: now)
        #expect(soon.wake == .renewal(after: .seconds(30)))
        #expect(soon.forceRefresh, "a token two margins from its expiry is renewed from a fresh one")
        #expect(ModelRouterLease.renewal(expiresAt: 1_000_050, now: now).wake == .renewal(after: .seconds(10)))
        #expect(ModelRouterLease.Wake.renewal(after: .seconds(1)).policy == .flexiblePreferEarly)
        #expect(ModelRouterLease.Wake.retry(after: .seconds(1)).policy == .flexibleNoSooner)
    }

    @Test func theRenewalComesEarlyNeverLate() async throws {
        let tokens = FakeLeaseTokens(subject: "u1")
        let relay = FakeRelay()
        let clock = ManualClock()
        let lease = Self.lease(tokens, relay, clock)
        lease.accountChanged("u1")
        try await clock.waitForSleeper()
        #expect(await relay.expiries == [tokens.expiry])
        let request = try #require(clock.sleepRequests.last)
        #expect(request.tolerance == WakeLeeway.window(delay: .seconds(3510), policy: .flexiblePreferEarly).tolerance)
        #expect(request.tolerance == .seconds(1))
        #expect(request.deadline.offset == .seconds(3509), "the renewal does not sleep its leeway short")
        #expect(request.deadline.offset + (request.tolerance ?? .zero) <= .seconds(3510), "the renewal may fire after its deadline")

        // At the renewal the bearer goes to the relay again, and the next renewal is armed behind it.
        clock.advance(by: .seconds(3509))
        await relay.waitForAttempts(2)
        try await clock.waitForSleeper()
        #expect(await relay.expiries == [tokens.expiry, tokens.expiry])
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(3509 * 2))
        lease.stop()
    }

    @Test func aFailedHandOverRetriesNoSoonerThanItsDelay() async throws {
        let tokens = FakeLeaseTokens(subject: "u1")
        let relay = FakeRelay(failures: 1)
        let clock = ManualClock()
        let lease = Self.lease(tokens, relay, clock)
        lease.accountChanged("u1")
        try await clock.waitForSleeper()
        let retry = try #require(clock.sleepRequests.last)
        #expect(retry.deadline.offset == ModelRouterLease.retryDelays[0], "the retry sleeps short of its delay")
        #expect(retry.tolerance == WakeLeeway.window(delay: ModelRouterLease.retryDelays[0]).tolerance)

        clock.advance(by: ModelRouterLease.retryDelays[0])
        await relay.waitForAttempts(2)
        try await clock.waitForSleeper()
        #expect(await relay.expiries == [tokens.expiry])
        #expect(clock.sleepRequests.last?.deadline.offset == ModelRouterLease.retryDelays[0] + .seconds(3509))
        lease.stop()
    }

    /// A lease on `relay` and `clock` whose wall clock reads an hour before `tokens`' expiry.
    private static func lease(_ tokens: FakeLeaseTokens, _ relay: FakeRelay, _ clock: ManualClock) -> ModelRouterLease {
        let issued = Date(timeIntervalSince1970: TimeInterval(tokens.expiry) - 3600)
        return ModelRouterLease(tokens: tokens, apiBaseURL: URL(string: "https://cmux.example")!, relay: relay.relay, clock: clock,
                                wallClock: { issued }, logger: Logger(subsystem: "test.cmux", category: "model-router-lease"))
    }
}

/// The local relay without acpmux: records each bearer's expiry, refuses the first `failures` hand-overs, and
/// never exits.
private actor FakeRelay {
    private(set) var expiries: [UInt64] = []
    private var attempts = 0
    private var failuresLeft: Int
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(failures: Int = 0) { failuresLeft = failures }

    nonisolated var relay: ModelRouterRelay {
        ModelRouterRelay(setUpstream: { _, _, expiresAt in try await self.setUpstream(expiresAt: expiresAt) },
                         waitUntilGone: { _ in false },
                         clearUpstream: {})
    }

    /// Returns once `count` hand-overs were tried.
    func waitForAttempts(_ count: Int) async {
        guard attempts < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    private func setUpstream(expiresAt: UInt64) throws -> Int? {
        attempts += 1
        defer {
            let ready = watchers.filter { $0.count <= attempts }
            watchers.removeAll { $0.count <= attempts }
            for watcher in ready { watcher.continuation.resume() }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw URLError(.cannotConnectToHost)
        }
        expiries.append(expiresAt)
        return 42
    }
}
