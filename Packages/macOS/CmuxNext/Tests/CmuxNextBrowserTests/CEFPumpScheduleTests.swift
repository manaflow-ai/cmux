import Foundation
import Testing
@testable import CmuxNextBrowser

/// Idle power (msg 2654): Chromium's delayed tasks reach the app as
/// `OnScheduleMessagePumpWork(delay_ms)`. An idle browser asks about 1.7 times
/// a second, so each wake should carry leeway the system can use to coalesce
/// it with other wakeups, as Chromium's own pump does (base's default 8 ms
/// leeway). A "now" request stays exact.
@Suite struct CEFPumpScheduleTests {
    @Test func aDelayedRequestCarriesLeeway() throws {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 600, now: 100)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.deadline - 100.6) < 1e-9)
        #expect(wake.tolerance == CEFPumpSchedule.delayedLeeway)
    }

    /// A short delay gets at most a tenth of itself, so a 16 ms task still
    /// runs within 1.6 ms of its time.
    @Test func aShortDelayGetsATenthOfItself() throws {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 16, now: 0)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.tolerance - 0.0016) < 1e-9)
    }

    @Test func aRequestForNowIsExact() throws {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 0, now: 0)
        let wake = try #require(schedule.nextWake)
        #expect(wake.tolerance == 0)
    }

    /// Demand-driven forks sleep until CEF asks: no wake without a request.
    @Test func anIdlePumpHasNoWake() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 0, now: 0)
        // `beginWork` is mutating, and #expect captures its receiver as a constant.
        let began = schedule.beginWork(now: 0)
        #expect(began)
        schedule.endWork(now: 0.001, elapsed: 0.001)
        #expect(schedule.nextWake == nil)
    }
}
