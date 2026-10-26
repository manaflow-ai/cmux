import CmuxNextWakeups
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
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 600, now: 100)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.deadline - 100.6) < 1e-9)
        #expect(wake.tolerance == CEFPumpSchedule.delayedLeeway)
    }

    /// A short delay gets at most a tenth of itself, so a 16 ms task still
    /// runs within 1.6 ms of its time.
    @Test func aShortDelayGetsATenthOfItself() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 16, now: 0)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.tolerance - 0.0016) < 1e-9)
    }

    @Test func aRequestForNowIsExact() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 0, now: 0)
        let wake = try #require(schedule.nextWake)
        #expect(wake.tolerance == 0)
    }

    /// The pump sleeps until CEF asks: no wake without a request.
    @Test func anIdlePumpHasNoWake() {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 0, now: 0)
        let began = schedule.beginWork(now: 0)
        #expect(began)
        schedule.endWork()
        #expect(schedule.nextWake == nil)
    }

    /// A pass that used CEF's whole 10 ms slice arms no follow-up wake: the
    /// fork asks for "now" itself when work remains (fork API 7), so the pump
    /// sleeps until CEF asks.
    @MainActor
    @Test func aLongPassArmsNoWake() {
        let timer = CEFPumpCrossThreadGateTests.Timer()
        let clock = CEFPumpCrossThreadGateTests.Clock()
        let pump = CEFMessagePump(work: { clock.seconds += 0.025 }, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger())
        pump.start()
        timer.fire()
        #expect(pump.stats.longWorkRuns == 1)
        #expect(timer.armed == nil, "armed \(String(describing: timer.armed)) after a long pass with no request")
    }

    /// A fire inside a running pass (a nested run loop) is deferred, and the
    /// pump runs again on the next run loop pass.
    @Test func aReenteredFireRunsAfterThePass() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 0, now: 0)
        let began = schedule.beginWork(now: 0)
        #expect(began)
        #expect(schedule.nextWake == nil, "no wake while a pass runs")
        let nested = schedule.beginWork(now: 0.001)
        #expect(!nested)
        schedule.endWork()
        let wake = try #require(schedule.nextWake)
        #expect(wake.deadline == -.infinity)
    }

    /// A delayed request served by a pass leaves no wake; a later one replaces it.
    @Test func aServedDelayedRequestLeavesNoWake() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 100, now: 0)
        schedule.request(milliseconds: 50, now: 0)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.deadline - 0.05) < 1e-9, "the later request replaces the earlier one")
        let served = schedule.beginWork(now: 0.05)
        #expect(served)
        schedule.endWork()
        #expect(schedule.nextWake == nil)
    }
}
