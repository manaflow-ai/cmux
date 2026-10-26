import CmuxNextInputCore
import CmuxNextSignposts
import CmuxNextWakeups
import CoreFoundation
import Foundation

/// Drives `CefDoMessageLoopWork` on the main thread when CEF asks for it
/// (`OnScheduleMessagePumpWork`, and the fork's absolute `cmux_on_schedule_delayed`
/// where it has one), in common modes, so it keeps running during
/// menu tracking, live resize and modal panels. `CEFPumpSchedule` decides each
/// fire date: the pump wakes only when CEF (or cmux) asks.
///
/// A delayed fire date is an entry on the main thread's one deadline queue
/// (`CEFWakeUpQueuePumpTimer`): it shares wakes with the cmux deadlines near
/// it, and the pass runs after them, in a run-loop block of its own. A
/// request for "now" runs on the next run loop pass, never synchronously
/// inside the CEF call that made it, and never waits for the queue's timer.
/// The timer is owned, re-armed for each request and invalidated by
/// `stop()`; there is no `asyncAfter`.
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
/// it (`RunDelayedWorkTimer` or `RunWorkSource`, base/message_loop/message_pump_apple.mm). The deadline
/// queue records no `deadline` for the pump's entries (``MainWakeUpQueue/LedgerReason/recordedByAction``).
///
/// Each pass is one `cef.pump` slice (``Signposter/beginCEFPump(reasonCode:)``): the reason it runs, whether it
/// used CEF's whole time slice and its time, like Chrome's `ThreadControllerWithMessagePumpImpl::DoWork` trace
/// event (base/task/sequence_manager/thread_controller_with_message_pump_impl.cc). The ring takes it only during a
/// recording (``SignpostName/cefPump``), never in the black box. Only the in-process pump
/// emits it: with the Chromium host on there is no pump in the app, and the host emits its own (p09 task 104).
///
/// Only the in-process backend makes one (``CEFRuntime/startInProcessPump(_:)``). In host mode the app has no
/// pump, no ``CEFPumpTimer`` and no schedule callback; the Chromium Host runs `CefRunMessageLoop`.
final class CEFMessagePump {
    /// The wakeup ledger owner of every pump wake.
    nonisolated static let ledgerOwner = "CEFMessagePump"

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

        /// The reason's number in a `cef.pump` begin record (`arg0`): fixed and nonzero, so 0 is a pass no timer
        /// armed (the quit path's drain). A reentered fire runs no pass; 4 marks the pass that runs it after the
        /// outer pass returns.
        var traceCode: UInt64 {
            switch self {
            case .now: 1
            case .delayed: 2
            case .kept: 3
            case .reentered: 4
            }
        }
    }

    private let work: () -> Void
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
    /// Takes each pass's `cef.pump` interval.
    private let signposter: Signposter
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
    private var earlyPassWatch: CEFPumpStats.EarlyPassWatch
    /// What Chromium threads ask whether a delayed request must wake the main thread.
    let gate: CEFPumpCrossThreadGate

    var stats: CEFPumpStats {
        var stats = counters
        stats.keptCrossThreadRequests = Int(clamping: gate.kept)
        return stats
    }

    /// `timer`: a `CEFWakeUpQueuePumpTimer` on the app's deadline queue (tests
    /// fire a fake by hand). `clock` is monotonic seconds (tests inject one).
    /// `starvation`: the app's rendering starvation guard; `CEFRuntime` passes
    /// none until the pump is on the main-thread board (p06-scheduler task 048). `signposter`: the `cef`
    /// category's (tests pass one on their own trace runtime). `absoluteRunTimes`: CEF sends delayed work
    /// as the fork's absolute run times (``request(runTimeNanos:leewayNanos:precise:fromChromiumThread:)``),
    /// which decides how ``CEFPumpStats/earlyPasses`` tells an early pass.
    init(
        work: @escaping () -> Void,
        timer: any CEFPumpTimer,
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime,
        ledger: WakeupLedger = .shared,
        gate: CEFPumpCrossThreadGate = CEFPumpCrossThreadGate(),
        starvation: RenderStarvationGuard? = nil,
        signposter: Signposter = .cef,
        absoluteRunTimes: Bool = false
    ) {
        earlyPassWatch = CEFPumpStats.EarlyPassWatch(absoluteRunTimes: absoluteRunTimes)
        self.work = work
        self.signposter = signposter
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

    /// Main thread: a CEF `OnScheduleMessagePumpWork(delay_ms)` request. `fromChromiumThread`: a
    /// Chromium thread made it and a run-loop block delivers it, so it is no re-ask of the running pass.
    func request(milliseconds: Int64, fromChromiumThread: Bool = false) {
        guard isRunning else { return }
        if !fromChromiumThread { earlyPassWatch.request(milliseconds: milliseconds) }
        enqueue(milliseconds: milliseconds)
    }

    /// Main thread: a fork `cmux_on_schedule_delayed` request (``CEFPumpSchedule/request(runTimeNanos:leewayNanos:precise:)``):
    /// CEF's next delayed work at an absolute uptime with Chromium's leeway. It is always a delayed
    /// request, never "now". `fromChromiumThread` as for ``request(milliseconds:fromChromiumThread:)``.
    func request(runTimeNanos: Int64, leewayNanos: Int64, precise: Bool, fromChromiumThread: Bool = false) {
        guard isRunning else { return }
        if let runTime = CEFPumpSchedule.runTime(nanos: runTimeNanos) {
            if !fromChromiumThread { earlyPassWatch.request(runTime: runTime) }
            counters.delayedRequests += 1
        }
        schedule.request(runTimeNanos: runTimeNanos, leewayNanos: leewayNanos, precise: precise)
        rearm()
    }

    /// Main thread: cmux changed CEF state outside a CEF callback and wants
    /// the result processed on the next run loop pass. It is no CEF re-ask (``CEFPumpStats/earlyPasses``).
    func scheduleNow() {
        guard isRunning else { return }
        enqueue(milliseconds: 0)
    }

    private func enqueue(milliseconds: Int64) {
        if milliseconds <= 0 { counters.immediateRequests += 1 } else { counters.delayedRequests += 1 }
        schedule.request(milliseconds: milliseconds, now: clock())
        rearm()
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
        // The fire date this pass serves, read before kept requests merge (none of them armed it).
        let served = reason == .delayed || reason == .kept ? schedule.nextWake.map(\.deadline).flatMap { $0.isFinite ? $0 : nil } : nil
        // Before any work: no request is kept against a fire that is already running, and those
        // kept until now join the schedule (rearm() publishes again after the pass).
        mergeKeptRequests()
        let started = clock()
        let traceReason: LedgerReason? = schedule.servesDeferredFire ? .reentered : reason
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
        earlyPassWatch.passBegan(serving: served, at: started)
        rearm()
        let interval = signposter.beginCEFPump(reasonCode: traceReason?.traceCode ?? 0)
        work()
        let elapsed = clock() - started
        let longRun = counters.recordWorkRun(elapsed: elapsed)
        signposter.endCEFPump(interval, longRun: longRun, elapsedMicros: UInt64(max(0, elapsed) * 1e6))
        if earlyPassWatch.passEnded(usedWholeSlice: longRun) { counters.earlyPasses += 1 }
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
        schedule.requestNoLater(than: TimeInterval(earliest) / 1e9, now: clock())
    }
}
