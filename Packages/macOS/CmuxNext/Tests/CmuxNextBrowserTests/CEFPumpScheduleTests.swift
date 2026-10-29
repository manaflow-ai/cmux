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

    /// A whole-millisecond request carries no policy: below 36 ms it is exact, as a precise task
    /// (`kDefaultMaxPreciseDelay`); above, it gets at most a tenth of itself, so a 50 ms task still
    /// runs within 5 ms of its time.
    @Test func aMillisecondRequestIsExactBelow36MsAndGetsATenthAbove() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(milliseconds: 16, now: 0)
        let sixteen = try #require(schedule.nextWake)
        #expect(sixteen.tolerance == 0)
        schedule.request(milliseconds: 35, now: 0)
        let thirtyFive = try #require(schedule.nextWake)
        #expect(thirtyFive.tolerance == 0)
        schedule.request(milliseconds: 50, now: 0)
        let fifty = try #require(schedule.nextWake)
        #expect(abs(fifty.tolerance - 0.005) < 1e-9)
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

    /// From the first fork API built on cef-cmux 066b083f (API 26, layer hosting, whose
    /// first commit has 066b083f as its parent) a pass runs at most the switch's 2 ms, no longer than
    /// one deadline-queue fire. The API 24 and 25 builds (the cmux.28 pin, the API 25 keychain line)
    /// lack that commit and keep CEF's 10 ms.
    @MainActor
    @Test func forksThatHonourTheSwitchRunAtMostTwoMilliseconds() {
        #expect(CEFPumpSchedule.pumpTimeSliceSwitchForkAPI == CEFLayerHosting.forkAPI)
        for forkAPI: Int32 in [26, 27, 32] {
            let slice = CEFPumpSchedule.timeSlice(forkAPI: forkAPI)
            #expect(slice > 0 && slice <= 0.002, "fork API \(forkAPI): \(slice) s")
            #expect(slice <= MainWakeUpQueue.fireBudget / .seconds(1))
        }
        for forkAPI: Int32 in [7, 24, 25] {
            #expect(CEFPumpSchedule.timeSlice(forkAPI: forkAPI) == 0.010, "fork API \(forkAPI)")
        }
    }

    /// A 3 ms pass used the whole slice of a fork that honours the switch (it may have left work), not
    /// the 10 ms of one that does not.
    @MainActor
    @Test(arguments: [(Int32(26), 1), (Int32(32), 1), (Int32(25), 0), (Int32(24), 0)])
    func aLongPassIsJudgedAgainstTheForksSlice(forkAPI: Int32, longRuns: Int) {
        let timer = CEFPumpCrossThreadGateTests.Timer()
        let clock = CEFPumpCrossThreadGateTests.Clock()
        let pump = CEFMessagePump(work: { clock.seconds += 0.003 }, timer: timer,
                                  timeSlice: CEFPumpSchedule.timeSlice(forkAPI: forkAPI), clock: { clock.seconds },
                                  ledger: WakeupLedger())
        pump.start()
        timer.fire()
        #expect(pump.stats.longWorkRuns == longRuns)
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
        #expect(!schedule.servesDeferredFire, "the pass that runs it has not begun")
        schedule.endWork()
        let wake = try #require(schedule.nextWake)
        #expect(wake.deadline == -.infinity)
        #expect(schedule.servesDeferredFire)
        let next = schedule.beginWork(now: 0.002)
        #expect(next)
        #expect(!schedule.servesDeferredFire, "only the next pass serves it")
        schedule.endWork()
        #expect(!schedule.servesDeferredFire)
    }

    // MARK: Absolute run times (fork `cmux_on_schedule_delayed`)

    /// The table of the absolute path: Chromium's run time and leeway are the wake as sent, with no
    /// whole-millisecond truncation (7.9 ms stays 7.9 ms) and no 36 ms rule (Chromium's own policy
    /// came with the leeway); a precise one is exact.
    nonisolated struct AbsoluteCase: Sendable {
        /// The run time after now, ns.
        var after: Int64
        var leeway: Int64
        var precise: Bool
        /// The wake's expected tolerance, seconds.
        var tolerance: TimeInterval
    }

    nonisolated static let absoluteTable = [
        AbsoluteCase(after: 7_900_000, leeway: 8_000_000, precise: false, tolerance: 0.008),
        AbsoluteCase(after: 7_900_000, leeway: 8_000_000, precise: true, tolerance: 0),
        AbsoluteCase(after: 7_900_000, leeway: 0, precise: true, tolerance: 0),
        AbsoluteCase(after: 100_000_000, leeway: 8_000_000, precise: false, tolerance: 0.008),
        AbsoluteCase(after: 600_000_000, leeway: 32_000_000, precise: false, tolerance: 0.032),
    ]

    @Test(arguments: Self.absoluteTable)
    func anAbsoluteRequestArmsAtItsRunTimeWithChromiumsLeeway(_ row: AbsoluteCase) throws {
        let now: Int64 = 100_000_000_000
        var schedule = CEFPumpSchedule()
        schedule.request(runTimeNanos: now + row.after, leewayNanos: row.leeway, precise: row.precise)
        let wake = try #require(schedule.nextWake)
        #expect(abs(wake.deadline - Double(now + row.after) / 1e9) < 1e-9, "armed at the run time, not \(wake.deadline)")
        #expect(abs(wake.tolerance - row.tolerance) < 1e-12, "\(row)")
    }

    /// On the pump: a 7.9 ms run time with 8 ms leeway arms the timer 7.9 ms out with tolerance 8 ms,
    /// a precise one with 0, and neither counts as an immediate request.
    @MainActor
    @Test func thePumpArmsAnAbsoluteRequestAtItsRunTime() throws {
        let rig = AbsoluteRig()
        rig.pump.request(runTimeNanos: rig.nanos(after: 0.0079), leewayNanos: 8_000_000, precise: false)
        let flexible = try #require(rig.timer.armed)
        #expect(abs(flexible.delay - 0.0079) < 1e-9, "7.9 ms, not 7 ms: \(flexible.delay)")
        #expect(abs(flexible.tolerance - 0.008) < 1e-12)
        rig.pump.request(runTimeNanos: rig.nanos(after: 0.0079), leewayNanos: 0, precise: true)
        let precise = try #require(rig.timer.armed)
        #expect(abs(precise.delay - 0.0079) < 1e-9)
        #expect(precise.tolerance == 0)
        #expect(rig.pump.stats.immediateRequests == 0, "the start's pass is no request; neither of these is one")
        #expect(rig.pump.stats.delayedRequests == 2)
    }

    /// No absolute request becomes "now": one whose run time has passed is a due deadline (it
    /// arms for the next run loop pass, with no immediate request), and "no delayed work" drops the
    /// last one.
    @Test func anAbsoluteRequestIsNeverImmediate() throws {
        var schedule = CEFPumpSchedule()
        schedule.request(runTimeNanos: 99_000_000_000, leewayNanos: 8_000_000, precise: false)
        let due = try #require(schedule.nextWake)
        #expect(due.deadline == 99, "a finite deadline, not the immediate -infinity")
        let began = schedule.beginWork(now: 100)
        #expect(began)
        schedule.endWork()
        #expect(schedule.nextWake == nil, "served by the pass")
        schedule.request(runTimeNanos: 100_050_000_000, leewayNanos: 8_000_000, precise: false)
        schedule.request(runTimeNanos: .max, leewayNanos: 0, precise: true)
        #expect(schedule.nextWake == nil, "no delayed work replaces the 50 ms request")
    }

    /// On absolute run times an on-time pass is not early, however close Chromium's next task is: a pass
    /// at its 7.9 ms run time answered with a task 0.5 ms later, or with "now" (work it posted), ran the
    /// task it was for. The 2 ms re-ask rule is the whole-millisecond path's only.
    @MainActor
    @Test func aPassAnsweredWithTheNextRunTimeIsNotEarly() {
        let rig = AbsoluteRig()
        rig.pump.request(runTimeNanos: rig.nanos(after: 0.0079), leewayNanos: 8_000_000, precise: false)
        rig.work = { rig.pump.request(runTimeNanos: rig.nanos(after: 0.0079), leewayNanos: 8_000_000, precise: false) }
        rig.fireAtArmedTime()
        #expect(rig.pump.stats.earlyPasses == 0)
        rig.work = { rig.pump.request(runTimeNanos: rig.nanos(after: 0.0005), leewayNanos: 8_000_000, precise: false) }
        rig.fireAtArmedTime()
        #expect(rig.pump.stats.earlyPasses == 0, "a task 0.5 ms after an on-time pass is the next task")
        rig.work = { rig.pump.request(milliseconds: 0) }
        rig.fireAtArmedTime()
        #expect(rig.pump.stats.earlyPasses == 0, "a \"now\" during an on-time pass is posted work")
    }

    /// A real early pass on absolute run times: one that began before the run time it serves (the
    /// timer kept an armed date 50 us before it), or one Chromium answers with the same run time again
    /// (the task was not due). Each counts once.
    @MainActor
    @Test func aPassBeforeItsRunTimeIsEarly() {
        let rig = AbsoluteRig()
        let runTime = rig.nanos(after: 0.0079)
        rig.pump.request(runTimeNanos: runTime, leewayNanos: 8_000_000, precise: false)
        rig.work = { rig.pump.request(runTimeNanos: runTime, leewayNanos: 8_000_000, precise: false) }
        rig.fireAtArmedTime(offset: -0.000_05)
        #expect(rig.pump.stats.earlyPasses == 1, "began 50 us before the run time, and Chromium sent it again")
        rig.work = {}
        rig.fireAtArmedTime(offset: -0.000_05)
        #expect(rig.pump.stats.earlyPasses == 2, "began before the run time")
        let next = rig.nanos(after: 0.010)
        rig.pump.request(runTimeNanos: next, leewayNanos: 8_000_000, precise: false)
        rig.work = { rig.pump.request(runTimeNanos: next, leewayNanos: 8_000_000, precise: false) }
        rig.fireAtArmedTime()
        #expect(rig.pump.stats.earlyPasses == 3, "on time by the clock, but Chromium reported the same run time")
    }

    /// The cross-thread gate compares uptime nanoseconds as the fork sent them: a run time 0.5 ms
    /// after the armed fire is kept (whole milliseconds cannot say 10.5 ms), one 1 us before it wakes
    /// the main thread, and "no delayed work" is neither kept nor a wake.
    @MainActor
    @Test func theGateComparesAbsoluteRunTimesInNanoseconds() {
        let rig = CEFPumpCrossThreadGateTests.rig()
        let armed = rig.clock.nanos + 10_000_000
        #expect(!rig.gate.admit(runTimeNanos: armed + 500_000, nowNanos: rig.clock.nanos), "10.5 ms: after the armed fire")
        #expect(rig.gate.admit(runTimeNanos: armed - 1_000, nowNanos: rig.clock.nanos), "1 us before it")
        #expect(!rig.gate.admit(runTimeNanos: nil, nowNanos: rig.clock.nanos))
        #expect(rig.pump.stats.keptCrossThreadRequests == 1)
        #expect(CEFPumpCrossThreadGateTests.crossThreadWakes(rig.ledger) == 1)
        #expect(CEFPumpSchedule.runTimeNanos(.max) == nil)
        #expect(CEFPumpSchedule.runTimeNanos(7_900_000) == 7_900_000)
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

/// A pump on a timer that records each arm's delay and tolerance, with a clock moved by hand
/// (uptime seconds; ``nanos(after:)`` gives the fork's run time).
@MainActor
private final class AbsoluteRig {
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: (delay: TimeInterval, tolerance: TimeInterval)?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) { armed = (delay, tolerance) }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
    }

    /// The clock and what a CEF pass does, which the pump's closures read.
    final class State {
        var seconds: TimeInterval = 100
        var work: () -> Void = {}
    }

    let timer: Timer
    let pump: CEFMessagePump
    private let state: State

    /// What a CEF pass does.
    var work: () -> Void {
        get { state.work }
        set { state.work = newValue }
    }

    init() {
        let state = State()
        let timer = Timer()
        self.state = state
        self.timer = timer
        pump = CEFMessagePump(work: { state.work() }, timer: timer, clock: { state.seconds }, ledger: WakeupLedger(),
                              absoluteRunTimes: true)
        pump.start()
        fire() // the start's immediate pass
    }

    /// The fork's run time `delay` seconds from now (uptime ns).
    func nanos(after delay: TimeInterval) -> Int64 {
        Int64(((state.seconds + delay) * 1e9).rounded())
    }

    /// Moves the clock to the armed fire, `offset` seconds off it (negative: before), and fires it.
    func fireAtArmedTime(offset: TimeInterval = 0) {
        if let armed = timer.armed { state.seconds += armed.delay + offset }
        fire()
    }

    private func fire() {
        timer.armed = nil
        timer.onFire?()
    }
}
