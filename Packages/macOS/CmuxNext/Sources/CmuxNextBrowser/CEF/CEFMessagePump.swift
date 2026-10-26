import CmuxNextInputCore
import CmuxNextWakeups
import CoreFoundation
import Foundation
import os

/// Drives `CefDoMessageLoopWork` on the main thread when CEF asks for it
/// (`OnScheduleMessagePumpWork`), from one timer on the main run loop in
/// common modes, so it keeps running during menu tracking, live resize and
/// modal panels. `CEFPumpSchedule` decides each fire date: the pump wakes
/// only when CEF (or cmux) asks.
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
/// dispatch ends, the next frame deadline or one refresh at most; after an
/// input AppKit delivered to a Chromium page, a due pass runs on the next run
/// loop pass, outside that input's dispatch.
///
/// Each timer fire is one main wake in the wakeup ledger (owner ``ledgerOwner``) with the reason it
/// fired (``LedgerReason``), as Chrome's `MessagePumpCFRunLoopBase` tells its wakes apart by what woke
/// it (`RunDelayedWorkTimer` or `RunWorkSource`, base/message_loop/message_pump_apple.mm).
final class CEFMessagePump {
    /// The wakeup ledger owner of every pump wake.
    static let ledgerOwner = "CEFMessagePump"

    /// Why a timer fire woke the main thread (`debug.wakeups` reason).
    nonisolated enum LedgerReason: String, CaseIterable, Sendable {
        /// An immediate request: `OnScheduleMessagePumpWork(0)` or cmux's own "pump now".
        case now
        /// The fire date of CEF's delayed request.
        case delayed
        /// The deadline of a Chromium thread's delayed request the gate kept (``CEFPumpCrossThreadGate``).
        case kept
        /// A fire while a pass was running (a nested run loop); the outer pass runs the pump again.
        case reentered
    }

    private let work: () -> Void
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
    private var schedule: CEFPumpSchedule
    private var isRunning = false
    private var counters = CEFPumpStats()
    /// Holds passes past one per late frame (nil: never).
    private let starvation: RenderStarvationGuard?
    /// The late frame the last pass ran in.
    private var slices = RenderStarvationGuard.Slices()
    /// A held fire waits for the late frame's tick.
    private var waitsForLateFrame = false
    /// Holds passes while a person's input is pending (nil: never).
    private var input: CEFPumpInputPolicy?
    /// While input holds a pass: the latest it waits (the policy's bound).
    private var inputHoldDeadline: TimeInterval?
    /// An input to a Chromium page was dispatched with a pass due: the next fire runs it whatever input
    /// is pending, at once.
    private var chromiumInputPass = false
    private var earlyPassWatch = CEFPumpStats.EarlyPassWatch()
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
        schedule = CEFPumpSchedule()
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
        chromiumInputPass = false
        timer.invalidate()
    }

    /// Main thread: the person's input holds passes from now on (``CEFPumpInputPolicy``).
    func setInputPolicy(_ policy: CEFPumpInputPolicy) {
        input?.stop()
        input = policy
        inputHoldDeadline = nil
        chromiumInputPass = false
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
        let now = clock()
        if earlyPassWatch.request(milliseconds: milliseconds, now: now) { counters.earlyPasses += 1 }
        schedule.request(milliseconds: milliseconds, now: now)
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
        let reason = fireReason()
        ledger.record(Self.ledgerOwner, reason: reason.rawValue)
        runDuePass(for: reason)
    }

    /// What this fire is for, read before the pass merges kept requests: those were kept because
    /// the armed fire came first, so none of them armed it.
    private func fireReason() -> LedgerReason {
        if schedule.isWorking { return .reentered }
        guard let wake = schedule.nextWake, wake.deadline.isFinite else { return .now }
        return wake.deadline == schedule.keptDeadline ? .kept : .delayed
    }

    /// Runs the pass that is due, unless pending input or a late frame holds it. The input policy
    /// goes first: a pass it holds takes no late frame's slice. A fire inside a running pass (a nested
    /// run loop) goes straight to the slice check and `fire()`, which defers it.
    private func runDuePass(for reason: LedgerReason) {
        var admission = CEFPumpInputPolicy.Admission.run
        if let input, !schedule.isWorking {
            let now = clock()
            admission = chromiumInputPass ? input.admitAfterDispatch(to: .chromiumPage, now: now) : input.admit(now: now)
            if case .hold(let deadline, let began) = admission {
                if began { counters.deferredForInput += 1 }
                inputHoldDeadline = deadline
                rearm()
                return
            }
        }
        if let starvation, !starvation.admitsSlice(&slices) {
            waitForLateFrame(starvation)
            return
        }
        switch admission {
        case .runAfterDispatch(let target): counters.passesWhileInputPending.add(target)
        case .runAtBound: counters.passesWhileInputPending.boundExpired += 1
        case .run, .hold: break
        }
        fire(for: reason)
    }

    /// An input's dispatch ended (outside its dispatch scope). A pass held for it is re-armed for the
    /// next run loop pass; after input AppKit delivered to a Chromium page, a due pass is armed for the
    /// next run loop pass and runs whatever input is pending (its input router and wheel acks run
    /// inside the pump). During a pass (a nested run loop) the outer pass re-arms when it returns.
    private func inputDispatchEnded(_ target: InputTarget) {
        guard isRunning, !schedule.isWorking, input != nil else { return }
        let wasHeld = inputHoldDeadline != nil
        inputHoldDeadline = nil
        guard let wake = schedule.nextWake, wake.deadline <= clock() + 0.001 else {
            // No pass is due any more (CEF moved its request later): no hold is left to bound.
            endInputHold()
            if wasHeld { rearm() }
            return
        }
        if target == .chromiumPage { chromiumInputPass = true }
        if wasHeld || chromiumInputPass { rearm() }
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

    /// `reason`: the timer fire that runs this pass; nil for the quit path's drain.
    private func fire(for reason: LedgerReason? = nil) {
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
        // This pass is the one any hold or Chromium input waited for.
        inputHoldDeadline = nil
        chromiumInputPass = false
        input?.holdEnded()
        earlyPassWatch.passBegan(servesFireDate: reason == .delayed || reason == .kept)
        rearm()
        pumpMark("pump-start")
        work()
        pumpMark("pump-end")
        let finished = clock()
        let elapsed = finished - started
        counters.workRuns += 1
        counters.workSeconds += elapsed
        if elapsed >= CEFPumpSchedule.timeSlice { counters.longWorkRuns += 1 }
        if earlyPassWatch.passEnded(at: finished, usedWholeSlice: elapsed >= CEFPumpSchedule.timeSlice) {
            counters.earlyPasses += 1
        }
        if input != nil { counters.passTimes.record(nanos: UInt64(max(0, elapsed) * 1e9)) }
        schedule.endWork()
        rearm()
    }

    private func rearm() {
        guard isRunning else { return }
        mergeKeptRequests()
        guard let wake = schedule.nextWake else {
            endInputHold()
            timer.disarm()
            return
        }
        let now = clock()
        // No pass is due before the hold's end (CEF moved its request later): none waits for input.
        if wake.deadline > max(now + 0.001, inputHoldDeadline ?? -.infinity) { endInputHold() }
        // A pass input holds fires at the hold's bound, unless the input's dispatch ends first.
        let deadline = max(wake.deadline, inputHoldDeadline ?? -.infinity)
        let exact = inputHoldDeadline != nil || chromiumInputPass
        timer.arm(after: max(0, deadline - now), tolerance: exact ? 0 : wake.tolerance)
        // An immediate pass is no deadline.
        guard wake.deadline.isFinite, wake.deadline > 0 else { return }
        gate.publish(deadlineNanos: UInt64(wake.deadline * 1e9))
    }

    /// No pass waits for input: the next hold starts its own bound.
    private func endInputHold() {
        inputHoldDeadline = nil
        input?.holdEnded()
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
