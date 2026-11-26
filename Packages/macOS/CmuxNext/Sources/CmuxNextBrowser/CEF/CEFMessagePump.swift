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
final class CEFMessagePump {
    private let work: () -> Void
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
    private var schedule: CEFPumpSchedule
    private var isRunning = false
    /// Why the timer is armed (for the wakeup ledger).
    private var armedReason = CEFPumpSchedule.Wake.Reason.scheduled
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The armed fire's kind for the ledger (bench builds): immediate, or delayed by how long it was armed for.
    private var armedDetail = ""
    /// The steps-only form (``defersToSteps``): when the last resize step began, and since when a timer pass waits for
    /// the next one (nil: none waits).
    private var lastStepStart: TimeInterval?
    private var heldSince: TimeInterval?
    #endif
    private var counters = CEFPumpStats()
    /// What Chromium threads ask whether a delayed request must wake the main thread.
    let gate: CEFPumpCrossThreadGate

    var stats: CEFPumpStats {
        var stats = counters
        stats.keptCrossThreadRequests = Int(clamping: gate.kept)
        return stats
    }

    /// `clock` is monotonic seconds (tests inject one).
    init(
        work: @escaping () -> Void,
        safetyNet: CEFPumpSchedule.SafetyNet = CEFPumpSchedule.standard,
        timer: any CEFPumpTimer = CEFRunLoopPumpTimer(),
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime,
        ledger: WakeupLedger = .shared,
        gate: CEFPumpCrossThreadGate = CEFPumpCrossThreadGate(),
        defersToSteps: Bool = CEFMessagePump.runsOnlyAtSteps
    ) {
        self.defersToSteps = defersToSteps
        self.work = work
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

    /// Lever 4e, `CMUX_NEXT_CEF_PUMP_AT_STEP=1` (a bench arm until measured; a `CMUX_NEXT_` launch knob, so the launch
    /// strip keeps it): the pump runs at the start of each resize step (``ResizeStepTimes/stepWillLayOut``).
    nonisolated static let runsAtStep = ["1", "steps"].contains(ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_PUMP_AT_STEP"])
    /// Its steps-only form, `CMUX_NEXT_CEF_PUMP_AT_STEP=steps` (a bench arm): while a live resize steps, the timer's
    /// passes also wait for the next step's start (at most ``stepDeferBound``), so Chromium's work never sits between a
    /// pointer event and the step it starts. With every page drawing each size the pump ran about 36 times a second in
    /// a corner drag, between the steps too, and an event waited longer for its step (input age p50 10 to 18-27 ms).
    nonisolated static let runsOnlyAtSteps = ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_PUMP_AT_STEP"] == "steps"
    /// A live resize steps while its last step began this recently; a longer pause (or its end) lets the timer run.
    static let liveStepWindow: TimeInterval = 0.1
    /// The longest a due timer pass waits for the next step's start: a paused pointer never starves the pages or
    /// Chromium's timers, and the resize's end runs what waited within this.
    static let stepDeferBound: TimeInterval = 0.016
    /// Whether this pump holds timer passes for a resize step's start (``runsOnlyAtSteps``; tests inject it).
    let defersToSteps: Bool
    /// A held pass that ran outside a step: at ``stepDeferBound`` because no step came (`bound`), or at the resize's end
    /// (`end`). The step log's `cef_pump_late` line: the ms it waited, and why.
    var onDeferredPassOutsideStep: ((Double, String) -> Void)?

    /// A live resize ended (a window's, or a pane divider's drag): a pass held for a step runs now, once, and the timer
    /// runs at its deadlines again.
    func resizeEnded() {
        guard isRunning, defersToSteps else { return }
        lastStepStart = nil
        guard let since = heldSince else { return }
        counters.stepDeferFlushes += 1
        onDeferredPassOutsideStep?((clock() - since) * 1_000, "end")
        fire()
    }

    /// The steps-only form: whether the timer's pass now waits for the next step's start. A live resize steps (a step
    /// began within ``liveStepWindow``) and the pass has waited less than ``stepDeferBound``.
    private func holdsForNextStep() -> Bool {
        let now = clock()
        guard let last = lastStepStart, now - last < Self.liveStepWindow else { return false }
        guard let since = heldSince else {
            heldSince = now
            counters.stepDeferred += 1
            return true
        }
        return now - since < Self.stepDeferBound - 0.000_5
    }

    /// The start of a resize step, before its layout: one pass when work CEF already asked for is due (a request whose
    /// deadline passed, or an immediate one still on its way from a Chromium thread). A live resize keeps the main
    /// thread busy in cmux's steps, and the timer got about 10 passes a second (window corner drags: Chromium's acks of
    /// each page's new size waited 55 ms p50, so the next size waited in Chromium's resize IPC throttle). Never
    /// re-entrant: nothing runs inside a pass (a step begun from a CEF callback). Returns the step log's detail of the
    /// pass that ran, nil when none did.
    func runIfDueAtStep() -> String? {
        guard isRunning else { return nil }
        lastStepStart = clock()
        guard !schedule.isWorking else {
            counters.stepSkippedInPass += 1
            return nil
        }
        let inFlight = gate.immediatePending
        mergeKeptRequests()
        let now = clock()
        let held = heldSince.map { (now - $0) * 1_000 }
        guard inFlight || held != nil || (schedule.nextWake.map { $0.deadline <= now } ?? false) else {
            counters.stepNotDue += 1
            return nil
        }
        if inFlight || held != nil { schedule.request(milliseconds: 0, now: now) }
        counters.stepRuns += 1
        fire()
        return " ran=1" + (inFlight ? " in_flight=1" : "") + (held.map { String(format: " deferred_ms=%.1f", $0) } ?? "")
    }

    private func timerFired() {
        guard isRunning else { return }
        // The steps-only form: in a live resize the pass waits for the next step's start (rearm() arms the rest of the
        // bound); one that waited the whole bound runs now.
        if defersToSteps, holdsForNextStep() {
            rearm()
            return
        }
        if let since = heldSince {
            counters.stepDeferTimeouts += 1
            onDeferredPassOutsideStep?((clock() - since) * 1_000, "bound")
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // Which fires wake the app at idle (task 21, step ca941dd8: "scheduled" was 3.8/s, the top source): a pass for
        // "now" mostly shares the wake of the request that asked for it; a delayed fire is a timer wake of its own.
        ledger.record("CEFMessagePump", reason: armedReason == .scheduled ? "scheduled (\(armedDetail))" : armedReason.rawValue)
        #else
        ledger.record("CEFMessagePump", reason: armedReason.rawValue)
        #endif
        if armedReason == .fallback { counters.followUpRuns += 1 }
        fire()
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
        if let since = heldSince {
            counters.stepDeferredMs += (started - since) * 1_000
            heldSince = nil
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
        let now = clock()
        var delay = max(0, wake.deadline - now)
        // A pass held for a step waits out its bound: a new request does not wake the timer sooner.
        if let since = heldSince { delay = max(delay, since + Self.stepDeferBound - now) }
        #if DEBUG || CMUX_BENCH_HOOKS
        armedDetail = Self.delayBucket(wake.deadline.isFinite ? delay : nil)
        #endif
        timer.arm(after: delay, tolerance: wake.tolerance)
        // Only a demand-driven fork (no safety net) reports its next delayed task after each pass;
        // with an older one every request reaches the schedule. An immediate pass is no deadline.
        guard schedule.safetyNet == .none, wake.deadline.isFinite, wake.deadline > 0 else { return }
        gate.publish(deadlineNanos: UInt64(wake.deadline * 1e9))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A fire's ledger detail: `immediate` (nil: a pass for "now"), else `delayed` and its armed delay's bucket.
    static func delayBucket(_ delay: TimeInterval?) -> String {
        guard let delay else { return "immediate" }
        switch delay {
        case ..<0.000_5: return "immediate"
        case ..<0.017: return "delayed <17ms"
        case ..<0.1: return "delayed <100ms"
        case ..<1: return "delayed <1s"
        default: return "delayed >=1s"
        }
    }
    #endif

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
        // An immediate request on its way counts as due work for a resize step's pass (lever 4e).
        let gate = delayMilliseconds <= 0 && CEFMessagePump.runsAtStep ? CEFRuntime.pumpGate(at: address) : nil
        gate?.immediatePosted()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            deliver()
            gate?.immediateDelivered()
        }
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
