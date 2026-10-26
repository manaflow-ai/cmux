import CmuxNextWakeups
import CoreFoundation
import Foundation
import os

/// Drives `CefDoMessageLoopWork` on the main thread when CEF asks for it
/// (`OnScheduleMessagePumpWork`), from one timer on the main run loop in
/// common modes, so it keeps running during menu tracking, live resize and
/// modal panels. `CEFPumpSchedule` decides each fire date; see there for
/// the safety net CEF's pump needs.
///
/// A request for "now" runs on the next run loop pass, never synchronously
/// inside the CEF call that made it. The timer is owned, re-armed for each
/// request and invalidated by `stop()`; there is no `asyncAfter`.
///
/// While a shown frame is late (`RenderStarvationGuard`, Chrome's
/// `kRenderingStarved`) a pump with the guard runs one pass per late frame;
/// the next waits for that link's tick (`afterLateFrame`), then runs on the
/// next run loop pass.
///
/// Each pass runs with the crash keys' CEF state at ``CrashKeySlots/CEFState/inPump``:
/// the pump runs on the main thread, so a stall or hang inside it is a phase of
/// the main thread's episode (the watchdog's records name it `cef_pump`), not a
/// hang-watch scope. A nested run loop inside a pass (a menu, a modal panel) runs
/// AppKit's work, not Chromium's: its first fire of the pump puts the state back
/// until the pass returns, as Chrome tracks a phase per run level
/// (base/task/sequence_manager/thread_controller.cc, `RunLevelTracker`).
final class CEFMessagePump {
    private let work: () -> Void
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
    /// The app's crash keys, told when a pass runs (nil: none).
    private let crashKeys: CrashKeySlots?
    /// The CEF state key before the running pass set it to `inPump`; nil between passes.
    private var stateOutsidePass: UInt64?
    private var schedule: CEFPumpSchedule
    private var isRunning = false
    /// Why the timer is armed (for the wakeup ledger).
    private var armedReason = CEFPumpSchedule.Wake.Reason.scheduled
    private var counters = CEFPumpStats()
    /// Holds passes past one per late frame (nil: never).
    private let starvation: RenderStarvationGuard?
    /// The late frame the last pass ran in.
    private var slices = RenderStarvationGuard.Slices()
    /// A held fire waits for the late frame's tick.
    private var waitsForLateFrame = false
    /// What Chromium threads ask whether a delayed request must wake the main thread.
    let gate: CEFPumpCrossThreadGate

    var stats: CEFPumpStats {
        var stats = counters
        stats.keptCrossThreadRequests = Int(clamping: gate.kept)
        return stats
    }

    /// `clock` is monotonic seconds (tests inject one). `starvation`: the app's
    /// rendering starvation guard; `CEFRuntime` passes none until the pump is
    /// on the main-thread board (p06-scheduler task 048). `crashKeys`: the
    /// app's (`CEFRuntime` passes the composition root's), a test's own, or nil.
    init(
        work: @escaping () -> Void,
        safetyNet: CEFPumpSchedule.SafetyNet = CEFPumpSchedule.standard,
        timer: any CEFPumpTimer = CEFRunLoopPumpTimer(),
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime,
        ledger: WakeupLedger = .shared,
        gate: CEFPumpCrossThreadGate = CEFPumpCrossThreadGate(),
        starvation: RenderStarvationGuard? = nil,
        crashKeys: CrashKeySlots?
    ) {
        self.work = work
        self.crashKeys = crashKeys
        self.starvation = starvation
        self.timer = timer
        self.clock = clock
        self.ledger = ledger
        self.gate = gate
        schedule = CEFPumpSchedule(safetyNet: safetyNet)
    }

    nonisolated static func uptime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer.onFire = { [weak self] in self?.timerFired() }
        schedule.request(milliseconds: 0, now: clock())
        rearm()
    }

    /// Cancels the timer for good; no `CefDoMessageLoopWork` runs after this
    /// (CefShutdown may follow).
    func stop() {
        isRunning = false
        _ = gate.take()
        timer.invalidate()
    }

    /// Main thread: a CEF `OnScheduleMessagePumpWork(delay_ms)` request.
    func request(milliseconds: Int64) {
        guard isRunning else { return }
        if milliseconds <= 0 { counters.immediateRequests += 1 } else { counters.delayedRequests += 1 }
        pumpMark("pump-req-\(min(milliseconds, 9_999))")
        schedule.request(milliseconds: milliseconds, now: clock())
        rearm()
    }

    /// Main thread: cmux changed CEF state outside a CEF callback and wants
    /// the result processed on the next run loop pass.
    func scheduleNow() {
        request(milliseconds: 0)
    }

    /// Runs one pump pass now (the quit path drains without the timer).
    func pumpNow() {
        fire()
    }

    private func timerFired() {
        guard isRunning else { return }
        ledger.record("CEFMessagePump", reason: armedReason.rawValue)
        if armedReason == .fallback { counters.followUpRuns += 1 }
        if let starvation, !starvation.admitsSlice(&slices) {
            waitForLateFrame(starvation)
            return
        }
        fire()
    }

    /// A late frame holds this fire: the schedule keeps its request, and the
    /// timer is armed again from it once the late link ticks.
    private func waitForLateFrame(_ starvation: RenderStarvationGuard) {
        counters.lateFrameHolds += 1
        guard !waitsForLateFrame else { return }
        waitsForLateFrame = true
        starvation.afterLateFrame { [weak self] in
            guard let self else { return }
            self.waitsForLateFrame = false
            self.rearm()
        }
    }

    private func fire() {
        guard isRunning else { return }
        // Before any work: no request is kept against a fire that is already running, and those
        // kept until now join the schedule (rearm() publishes again after the pass).
        mergeKeptRequests()
        let started = clock()
        guard schedule.beginWork(now: started) else {
            // CefDoMessageLoopWork re-entered through a nested run loop (menu,
            // modal panel). The outer pass runs the pump again when it returns.
            counters.reentrantFires += 1
            if let stateOutsidePass { crashKeys?.set(.cefState, stateOutsidePass) } // the nested loop is not the pump
            rearm()
            return
        }
        rearm()
        pumpMark("pump-start")
        runPass()
        pumpMark("pump-end")
        let finished = clock()
        let elapsed = finished - started
        counters.workRuns += 1
        counters.workSeconds += elapsed
        if elapsed >= CEFPumpSchedule.timeSlice { counters.longWorkRuns += 1 }
        schedule.endWork(now: finished, elapsed: elapsed)
        rearm()
    }

    /// One `CefDoMessageLoopWork`, with the CEF state key at `inPump` and the value before it put back after.
    private func runPass() {
        guard let crashKeys else { work(); return }
        let outside = crashKeys.value(.cefState)
        stateOutsidePass = outside
        crashKeys.set(.cefState, CrashKeySlots.CEFState.inPump.rawValue)
        work()
        crashKeys.set(.cefState, outside)
        stateOutsidePass = nil
    }

    private func rearm() {
        guard isRunning else { return }
        mergeKeptRequests()
        counters.fallbackInterval = schedule.armedSafetyNetInterval ?? 0
        guard let wake = schedule.nextWake else {
            timer.disarm()
            return
        }
        armedReason = wake.reason
        timer.arm(after: max(0, wake.deadline - clock()), tolerance: wake.tolerance)
        // Only a demand-driven fork (no safety net) reports its next delayed task after each pass;
        // with an older one every request reaches the schedule. An immediate pass is no deadline.
        guard schedule.safetyNet == .none, wake.deadline.isFinite, wake.deadline > 0 else { return }
        gate.publish(deadlineNanos: UInt64(wake.deadline * 1e9))
    }

    /// Takes the requests the gate kept (it keeps none from now until the next publish) into the
    /// schedule: no later than the earliest of them.
    private func mergeKeptRequests() {
        guard let earliest = gate.take() else { return }
        schedule.requestNoLater(than: TimeInterval(earliest) / 1e9)
    }
}

/// C entry for `OnScheduleMessagePumpWork`. `ctx` is the unretained
/// `CEFRuntime`, which lives for the rest of the process once started.
let cefScheduleCallback: CEFShimLibrary.ScheduleFn = { context, delayMilliseconds in
    guard let context else { return }
    let address = UInt(bitPattern: context)
    if !Thread.isMainThread,
       let gate = CEFRuntime.pumpGate(at: address),
       !gate.admit(delayMilliseconds: delayMilliseconds, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
        return // kept for the main thread's next pass or re-arm, with no wake (CEFPumpCrossThreadGate)
    }
    let deliver: @Sendable () -> Void = {
        MainActor.assumeIsolated { // main-proof: deliver runs only in the Thread.isMainThread branch or as a CFRunLoopGetMain() block (below)
            CEFRuntime.from(address)?.pump?.request(milliseconds: delayMilliseconds)
        }
    }
    if Thread.isMainThread {
        deliver()
    } else {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, deliver)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Tab switch timeline marks (cx-asb1): each pump pass and CEF request with
/// wall-clock ms. Debug level: nothing is formatted or written unless a
/// `log stream --level debug` reads category "tab-switch".
private let pumpLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
private func pumpMark(_ name: @escaping @autoclosure () -> String) {
    pumpLog.debug("tab-switch \(name(), privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
}
