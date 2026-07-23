import CmuxFleet
import Testing

@Suite("FleetBackoff")
struct FleetBackoffTests {
    @Test func clampsAttemptsBelowOneToFirstAttempt() {
        let backoff = FleetBackoff(maxMS: 300_000)

        #expect(backoff.delayMS(attempt: 0) == 10_000)
        #expect(backoff.delayMS(attempt: -4) == 10_000)
    }

    @Test func growsExponentiallyUntilCap() {
        let backoff = FleetBackoff(maxMS: 300_000)

        #expect(backoff.delayMS(attempt: 1) == 10_000)
        #expect(backoff.delayMS(attempt: 2) == 20_000)
        #expect(backoff.delayMS(attempt: 3) == 40_000)
        #expect(backoff.delayMS(attempt: 6) == 300_000)
    }

    @Test func respectsSmallAndNonPositiveCaps() {
        #expect(FleetBackoff(maxMS: 7_500).delayMS(attempt: 1) == 7_500)
        #expect(FleetBackoff(maxMS: 0).delayMS(attempt: 1) == 0)
        #expect(FleetBackoff(maxMS: -1).delayMS(attempt: 1) == 0)
    }

    @Test func handlesVeryLargeAttemptsWithoutOverflow() {
        #expect(FleetBackoff(maxMS: 300_000).delayMS(attempt: Int.max) == 300_000)
        #expect(FleetBackoff(maxMS: Int.max).delayMS(attempt: 128) == Int.max)
    }
}
