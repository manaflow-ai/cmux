import CmuxMobileFeed
import Foundation
import Testing

/// The Feed said "Connecting to your Mac…" with a spinner forever when no Mac
/// ever answered. After `FeedStore.connectDeadline` at `.connecting` it now
/// reports `connectTimedOut` (the screen shows "Your Macs are offline" with
/// Retry); the Mac's events arriving replace it, and Retry starts over.
@MainActor
@Suite struct FeedConnectDeadlineTests {
    static var deadline: LinkTestClock.Instant { LinkTestClock.Instant(offset: FeedStore.connectDeadline) }

    static func connectingStore(_ clock: LinkTestClock) -> FeedStore {
        let store = FeedStore(items: [])
        store.connectClock = clock
        store.syncState = .connecting
        return store
    }

    @Test func connectingPastTheDeadlineTimesOut() async throws {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let store = Self.connectingStore(clock)
        try await waitFor { clock.isSleeping(until: Self.deadline) }
        clock.advance(by: FeedStore.connectDeadline - .seconds(1))
        await Task.yield()
        #expect(!store.connectTimedOut)

        clock.advance(by: .seconds(1))
        try await waitFor { store.connectTimedOut }
    }

    @Test func theMacsEventsAfterTheDeadlineReplaceTheOfflineState() async throws {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let store = Self.connectingStore(clock)
        try await waitFor { clock.isSleeping(until: Self.deadline) }
        clock.advance(by: FeedStore.connectDeadline)
        try await waitFor { store.connectTimedOut }

        store.syncState = .live
        #expect(!store.connectTimedOut)
    }

    @Test func goingLiveInTimeNeverTimesOut() async throws {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let store = Self.connectingStore(clock)
        try await waitFor { clock.isSleeping(until: Self.deadline) }
        store.syncState = .live
        try await waitFor { !clock.isSleeping(until: Self.deadline) }
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(!store.connectTimedOut)
    }

    @Test func retryGoesBackToConnectingWithAFreshDeadline() async throws {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let store = Self.connectingStore(clock)
        try await waitFor { clock.isSleeping(until: Self.deadline) }
        clock.advance(by: FeedStore.connectDeadline)
        try await waitFor { store.connectTimedOut }

        var reconnects = 0
        await store.retryConnecting(reconnect: { reconnects += 1 })
        #expect(reconnects == 1)
        #expect(!store.connectTimedOut)
        let second = LinkTestClock.Instant(offset: FeedStore.connectDeadline * 2)
        try await waitFor { clock.isSleeping(until: second) }
        clock.advance(by: FeedStore.connectDeadline)
        try await waitFor { store.connectTimedOut }
    }

    /// Mock mode and a Feed that never connects stay as they were.
    @Test func aLiveFeedNeverArmsTheDeadline() async throws {
        let clock = LinkTestClock()
        defer { clock.stop() }
        let store = FeedStore(items: [])
        store.connectClock = clock
        store.syncState = .live
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(!store.connectTimedOut)
        #expect(!clock.isSleeping(until: Self.deadline))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > limit {
                Issue.record("condition not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
