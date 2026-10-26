import CmuxNextInputCore
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
/// With an input policy (``CEFPumpInputPolicy``, feature `cefPumpInputPolicy`)
/// a due pass waits while a person's input is pending, until that input's
/// dispatch ends and one refresh at most; after an input dispatched to a
/// Chromium page, a due pass runs at once.
final class CEFMessagePump {
    private let work: () -> Void
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
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
    /// Holds passes while a person's input is pending (nil: never).
    private var input: CEFPumpInputPolicy?
    /// While input holds a pass: the latest it waits (the policy's one-refresh bound).
    private var inputHoldDeadline: TimeInterval?
    /// What Chromium threads ask whether a delayed request must wake the main thread.
    let gate: CEFPumpCrossThreadGate

    var stats: CEFPumpStats {
        var stats = counters
        stats.keptCrossThreadRequests = Int(clamping: gate.kept)
        return stats
    }

    /// `clock` is monotonic seconds (tests inject one). `starvation`: the app's
    /// rendering starvation guard; `CEFRuntime` passes none until the pump is
    /// on the main-thread board (p06-scheduler task 048).
    init(
        work: @escaping () -> Void,
        safetyNet: CEFPumpSchedule.SafetyNet = CEFPumpSchedule.standard,
        timer: any CEFPumpTimer = CEFRunLoopPumpTimer(),
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime,
        ledger: WakeupLedger = .shared,
        gate: CEFPumpCrossThreadGate = CEFPumpCrossThreadGate(),
        starvation: RenderStarvationGuard? = nil
    ) {
        self.work = work
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
        input?.stop()
        input = nil
        inputHoldDeadline = nil
        timer.invalidate()
    }

    /// Main thread: the person's input holds passes from now on (``CEFPumpInputPolicy``).
    func setInputPolicy(_ policy: CEFPumpInputPolicy) {
        input?.stop()
        input = policy
        inputHoldDeadline = nil
        policy.onDispatchEnd { [weak self] target in self?.inputDispatchEnded(target) }
    }

    /// Starts the input policy's counters over (`debug.input` action `reset`).
    func resetInputCounters() {
        counters.passesWhileInputPending = CEFPumpStats.PassesByTarget()
        counters.deferredForInput = 0
        counters.passTimes = InputLatencyHistogram()
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
        runDuePass(afterChromiumDispatch: false)
    }

    /// Runs the pass that is due, unless a late frame or pending input holds it. A fire inside a
    /// running pass (a nested run loop) goes straight to `fire()`, which defers it.
    private func runDuePass(afterChromiumDispatch: Bool) {
        if let starvation, !starvation.admitsSlice(&slices) {
            waitForLateFrame(starvation)
            return
        }
        guard let input, !schedule.isWorking else {
            fire()
            return
        }
        let now = clock()
        switch afterChromiumDispatch ? input.admitAfterChromiumDispatch(now: now) : input.admit(now: now) {
        case .run:
            break
        case .runWhileInputPending(let target):
            counters.passesWhileInputPending.add(target)
        case .hold(let deadline, let began):
            if began { counters.deferredForInput += 1 }
            inputHoldDeadline = deadline
            rearm()
            return
        }
        inputHoldDeadline = nil
        fire()
    }

    /// An input's dispatch ended. A pass held for it is re-armed for the next run loop pass; after
    /// input to a Chromium page, a due pass runs now (its input router and wheel acks run inside
    /// the pump). During a pass (a nested run loop) the outer pass re-arms when it returns.
    private func inputDispatchEnded(_ target: CEFPumpInputPolicy.Target) {
        guard isRunning, !schedule.isWorking, input != nil else { return }
        let wasHeld = inputHoldDeadline != nil
        inputHoldDeadline = nil
        if target == .chromiumPage, let wake = schedule.nextWake, wake.deadline <= clock() + 0.001 {
            runDuePass(afterChromiumDispatch: true)
        } else if wasHeld {
            rearm()
        }
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
            rearm()
            return
        }
        rearm()
        pumpMark("pump-start")
        work()
        pumpMark("pump-end")
        let finished = clock()
        let elapsed = finished - started
        counters.workRuns += 1
        counters.workSeconds += elapsed
        if elapsed >= CEFPumpSchedule.timeSlice { counters.longWorkRuns += 1 }
        if input != nil { counters.passTimes.record(nanos: UInt64(max(0, elapsed) * 1e9)) }
        schedule.endWork(now: finished, elapsed: elapsed)
        rearm()
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
        // A pass input holds fires at the hold's bound, unless the input's dispatch ends first.
        let deadline = max(wake.deadline, inputHoldDeadline ?? -.infinity)
        timer.arm(after: max(0, deadline - clock()), tolerance: inputHoldDeadline == nil ? wake.tolerance : 0)
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
