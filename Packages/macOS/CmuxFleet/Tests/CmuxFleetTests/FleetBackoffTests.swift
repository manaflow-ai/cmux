import CmuxFleet
import Testing

@Suite("FleetBackoff")
struct FleetBackoffTests {
    @Test func clampsAttemptsBelowOneToFirstAttempt() {
        #expect(FleetBackoff.delayMS(attempt: 0, maxMS: 300_000) == 10_000)
        #expect(FleetBackoff.delayMS(attempt: -4, maxMS: 300_000) == 10_000)
    }

    @Test func growsExponentiallyUntilCap() {
        #expect(FleetBackoff.delayMS(attempt: 1, maxMS: 300_000) == 10_000)
        #expect(FleetBackoff.delayMS(attempt: 2, maxMS: 300_000) == 20_000)
        #expect(FleetBackoff.delayMS(attempt: 3, maxMS: 300_000) == 40_000)
        #expect(FleetBackoff.delayMS(attempt: 6, maxMS: 300_000) == 300_000)
    }

    @Test func respectsSmallAndNonPositiveCaps() {
        #expect(FleetBackoff.delayMS(attempt: 1, maxMS: 7_500) == 7_500)
        #expect(FleetBackoff.delayMS(attempt: 1, maxMS: 0) == 0)
        #expect(FleetBackoff.delayMS(attempt: 1, maxMS: -1) == 0)
    }

    @Test func handlesVeryLargeAttemptsWithoutOverflow() {
        #expect(FleetBackoff.delayMS(attempt: Int.max, maxMS: 300_000) == 300_000)
        #expect(FleetBackoff.delayMS(attempt: 128, maxMS: Int.max) == Int.max)
    }
}
