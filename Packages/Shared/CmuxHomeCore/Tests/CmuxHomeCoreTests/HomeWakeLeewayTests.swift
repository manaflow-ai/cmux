import Testing
@testable import CmuxHomeCore

/// Home's waits are flexible, so the kernel can fold them into wakes that happen
/// anyway (plans/cmux-next/chrome-parity/p14-energy.md B), and a keepalive pings only after quiet.
@Suite struct HomeWakeLeewayTests {
    @Test func theLeewayFollowsChromiumBelowOneSecondAndTenPercentAbove() {
        #expect(HomeWakeLeeway(delay: .zero).tolerance == .zero)
        #expect(HomeWakeLeeway(delay: .seconds(-1)).tolerance == .zero)
        #expect(HomeWakeLeeway(delay: .milliseconds(250)).tolerance == .milliseconds(8))
        #expect(HomeWakeLeeway(delay: .seconds(1)).tolerance == .milliseconds(100))
        #expect(HomeWakeLeeway(delay: .seconds(5)).tolerance == .milliseconds(500))
        #expect(HomeWakeLeeway(delay: .seconds(25)).tolerance == .seconds(1))
        #expect(HomeWakeLeeway(delay: .seconds(6 * 3_600)).tolerance == .seconds(1))
    }

    @Test func aPingIsDueAnIntervalAfterTheLaterOfThePingAndTheLastFrame() {
        let schedule = HomeKeepaliveSchedule(interval: .seconds(25))
        let start = ManualClock.Instant(offset: .zero)
        let at = { (seconds: Int64) in ManualClock.Instant(offset: .seconds(seconds)) }
        #expect(schedule.nextPing(afterPing: start, lastInbound: nil) == at(25))
        #expect(schedule.nextPing(afterPing: start, lastInbound: start) == at(25))
        #expect(schedule.nextPing(afterPing: at(30), lastInbound: at(20)) == at(55))
        #expect(schedule.nextPing(afterPing: start, lastInbound: at(20)) == at(45))
    }
}
