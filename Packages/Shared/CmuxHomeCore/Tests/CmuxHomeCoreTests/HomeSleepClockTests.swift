import Foundation
import Testing
@testable import CmuxHomeCore

/// The clock Home sleeps on: `Task.sleep(nanoseconds:)`, because the macOS 15
/// runtime traps when a `Task.sleep(for:)` sleep races with cancellation.
@Suite struct HomeSleepClockTests {
    @Test func durationsBecomeWholeNanosecondsWithinRange() {
        #expect(HomeSleepClock.nanoseconds(.milliseconds(2)) == 2_000_000)
        #expect(HomeSleepClock.nanoseconds(.seconds(3) + .nanoseconds(7)) == 3_000_000_007)
        #expect(HomeSleepClock.nanoseconds(.zero - .seconds(1)) == 0)
        #expect(HomeSleepClock.nanoseconds(.seconds(Int64.max)) == .max)
    }

    @Test func aPassedDeadlineReturnsAtOnce() async throws {
        let clock = HomeSleepClock()
        try await clock.sleep(until: clock.now.advanced(by: .zero - .seconds(1)))
    }

    /// The pruning and backoff loops are cancelled mid-sleep: the sleep ends with
    /// `CancellationError` instead of running to its deadline.
    @Test(.timeLimit(.minutes(1))) func cancellingTheSleepEndsIt() async {
        let sleeper = Task { try await Self.sleepAnHour() }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }

    /// A sleep the test cancels, never one it waits out.
    static func sleepAnHour() async throws {
        try await HomeSleepClock().sleep(for: .seconds(3_600))
    }
}
