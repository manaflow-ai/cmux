import Testing
@testable import CmuxUpdater

/// The production ``UpdateClock`` sleeps are flexible deadlines (Chromium's default
/// `kFlexibleNoSooner`, base/task/delay_policy.h): they never fire early and may fire late by the
/// leeway, so the kernel can fold an updater wake into one the Mac takes anyway.
@MainActor
@Suite struct UpdateClockLeewayTests {
    /// Below one second the leeway is Chromium's `kDefaultLeeway` (base/task/task_features.cc).
    @Test func subSecondDelaysGetTheDefaultEightMillisecondLeeway() {
        #expect(SystemUpdateClock.tolerance(for: .milliseconds(250)) == .milliseconds(8))
        #expect(SystemUpdateClock.tolerance(for: .milliseconds(20)) == .milliseconds(8))
    }

    /// From one second on the leeway is 10% of the delay (Blink's 1 s wake-up budget pool).
    @Test func secondScaleDelaysGetTenPercent() {
        #expect(SystemUpdateClock.tolerance(for: .seconds(1)) == .milliseconds(100))
        #expect(SystemUpdateClock.tolerance(for: UpdateRelaunchGate.recheckInterval) == .milliseconds(200))
        #expect(SystemUpdateClock.tolerance(for: .seconds(5)) == .milliseconds(500))
    }

    /// The leeway never exceeds one second: a 20 s wake check or a 25 s watchdog stays on time
    /// to the second.
    @Test func longDelaysCapTheLeewayAtOneSecond() {
        #expect(SystemUpdateClock.tolerance(for: .seconds(10)) == .seconds(1))
        #expect(SystemUpdateClock.tolerance(for: UpdateController.wakeCheckDelay) == .seconds(1))
        #expect(SystemUpdateClock.tolerance(for: .seconds(installWatchdogTimeout)) == .seconds(1))
    }
}
