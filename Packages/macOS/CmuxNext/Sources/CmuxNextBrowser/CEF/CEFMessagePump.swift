import CmuxNextInputCore
import CmuxNextSignposts
import CmuxNextTrace
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
/// With a board (``CEFPumpBoard``) each pass is a task of owner `cef.pump` on the main-thread budget,
/// in the input class while a page has the keyboard or a page input's ack may be due and the frame
/// class otherwise (``CEFPumpSchedule/workClass(pageHasFocus:pageInputRecent:)``). An input-class pass
/// takes no late frame's slice; pending keys to the page with the keyboard and input after a page
/// input do not hold it (Chromium acks the page's input inside the pump), pending pointer input does.
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
/// emits it and its `cef.pump` histogram sample (task 060): in host mode the app has no pump, the host emits its own (104).
///
/// Only the in-process backend makes one (``CEFInProcessPump``). In host mode the app has no
/// pump, no ``CEFPumpTimer`` and no schedule callback; the Chromium Host runs `CefRunMessageLoop`.
///
/// Each pass runs with the crash keys' CEF state at ``CrashKeySlots/CEFState/inPump`` and
/// the trace runtime's `in_cef_pump` key (``CmuxNextTrace/CrashKeySlot/inCEFPump``) at 1, in
/// whichever process runs the pump (task 077): the pump runs on the main thread, so a stall or
/// hang inside it is a phase of the main thread's episode (the watchdog's records carry
/// `cef=true` and the phase `cef_pump`, its Sentry events the tag `hang.cef`), not a
/// hang-watch scope. A nested run loop inside a pass (a menu, a modal panel) runs
/// AppKit's work, not Chromium's: its first fire of the pump puts the state back
/// until the pass returns, as Chrome tracks a phase per run level
/// (base/task/sequence_manager/thread_controller.cc, `RunLevelTracker`).
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
    /// The fork's longest pass (``CEFPumpSchedule/timeSlice(forkAPI:)``): a pass this long may have left work.
    private let timeSlice: TimeInterval
    private let timer: any CEFPumpTimer
    private let clock: () -> TimeInterval
    private let ledger: WakeupLedger
    /// Takes each pass's `cef.pump` interval.
    private let signposter: Signposter
    /// The app's crash keys, told when a pass runs (nil: none).
    private let crashKeys: CrashKeySlots?
    /// The process's trace runtime: each pass sets its `in_cef_pump` crash key.
    private let trace: TraceRuntime
    /// The crash keys before the running pass set them (the CEF state, nil without ``crashKeys``, and
    /// `in_cef_pump`); nil between passes.
    private var keysOutsidePass: (cefState: UInt64?, inCEFPump: UInt64)?
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
    /// The main-thread task board each pass runs on (nil: unattributed, classed by nothing).
    private let board: CEFPumpBoard?
    /// Follows the board's input dispatch ends while the pump runs with no input policy (the policy's
    /// own follower tells the pump otherwise: one tap observer either way).
    private var boardDispatches: InputSubscription?
    /// The last input AppKit delivered to a Chromium page, while its ack may be due.
    private var pageInput = CEFPumpSchedule.RecentPageInput()

    var stats: CEFPumpStats {
        var stats = counters
        stats.keptCrossThreadRequests = Int(clamping: gate.kept)
        return stats
    }

    /// `timer`: a `CEFWakeUpQueuePumpTimer` on the app's deadline queue (tests
    /// fire a fake by hand). `clock` is monotonic seconds (tests inject one).
    /// `starvation`: a rendering starvation guard. `CEFRuntime` passes none: a late frame must not slow a
    /// hidden tab's CDP round trip (p06-scheduler-048 acceptance). `signposter`: the `cef`
    /// category's (tests pass one on their own trace runtime). `absoluteRunTimes`: CEF sends delayed work
    /// as the fork's absolute run times (``request(runTimeNanos:leewayNanos:precise:fromChromiumThread:)``),
    /// which decides how ``CEFPumpStats/earlyPasses`` tells an early pass.
    /// `timeSlice`: the loaded fork's (``CEFPumpSchedule/timeSlice(forkAPI:)``).
    /// `crashKeys`: the app's (`CEFRuntime` passes the composition root's), a test's own, or nil.
    /// `board`: the main-thread budget each pass runs on as owner `cef.pump` (nil: none).
    /// `trace`: the runtime of the process that runs the pump, whose `in_cef_pump` key each pass sets
    /// (tests pass their own).
    init(
        work: @escaping () -> Void,
        timer: any CEFPumpTimer,
        timeSlice: TimeInterval = CEFPumpSchedule.timeSlice,
        clock: @escaping () -> TimeInterval = CEFMessagePump.uptime,
        ledger: WakeupLedger = .shared,
        gate: CEFPumpCrossThreadGate = CEFPumpCrossThreadGate(),
        starvation: RenderStarvationGuard? = nil,
        signposter: Signposter = .cef,
        absoluteRunTimes: Bool = false,
        crashKeys: CrashKeySlots? = nil,
        board: CEFPumpBoard? = nil,
        trace: TraceRuntime = .shared
    ) {
        earlyPassWatch = CEFPumpStats.EarlyPassWatch(absoluteRunTimes: absoluteRunTimes)
        self.work = work
        self.signposter = signposter
        self.timeSlice = timeSlice
        self.crashKeys = crashKeys
        self.board = board
        self.trace = trace
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
        if input == nil {
            boardDispatches = board?.dispatches?.observeDispatchEnd { [weak self] target in self?.notePageDispatch(target) }
        }
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
        boardDispatches?.cancel()
        boardDispatches = nil
        pageInput = CEFPumpSchedule.RecentPageInput()
        timer.invalidate()
    }

    /// Main thread: the person's input holds passes from now on (``CEFPumpInputPolicy``).
    func setInputPolicy(_ policy: CEFPumpInputPolicy) {
        input?.stop()
        input = policy
        inputHoldDeadline = nil
        chromiumInputPass = false
        // The policy's follower tells the pump of page input too.
        boardDispatches?.cancel()
        boardDispatches = nil
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
    /// run loop) goes straight to the slice check and `fire()`, which defers it. On the board, a pass
    /// in the input class takes no late frame's slice either.
    private func runDuePass(for reason: LedgerReason) {
        let now = clock()
        let workClass = boardClass(at: now)
        var admission = CEFPumpInputPolicy.Admission.run
        if let input, !schedule.isWorking {
            admission = admit(input, now: now)
            if case .hold(let deadline, let began) = admission {
                if began { counters.deferredForInput += 1 }
                inputHoldDeadline = deadline
                rearm()
                return
            }
        }
        if workClass != .input, let starvation, !starvation.admitsSlice(&slices) {
            waitForLateFrame(starvation)
            return
        }
        switch admission {
        case .runAfterDispatch(let target): counters.passesWhileInputPending.add(target)
        case .runAtBound: counters.passesWhileInputPending.boundExpired += 1
        case .runForFocusedPage: counters.passesWhileInputPending.add(.chromiumPage)
        case .run, .hold: break
        }
        fire(for: reason, workClass: workClass)
    }

    /// The policy's answer for the pass due at `now`. Right after an input to a page, and on the board
    /// while that input's ack may be due, the pass runs whatever is pending; while a page has the
    /// keyboard, pending keys do not hold it.
    private func admit(_ input: CEFPumpInputPolicy, now: TimeInterval) -> CEFPumpInputPolicy.Admission {
        if chromiumInputPass || pageInputRecent(at: now) { return input.admitAfterDispatch(to: .chromiumPage, now: now) }
        return input.admit(now: now, pageHasKeyboard: board?.pageHasFocus == true)
    }

    /// The board class of a pass that starts at `now`; nil without a board.
    private func boardClass(at now: TimeInterval) -> MainWorkClass? {
        guard let board else { return nil }
        return CEFPumpSchedule.workClass(pageHasFocus: board.pageHasFocus, pageInputRecent: pageInputRecent(at: now))
    }

    /// On the board: a page input's ack may still be due at `now`.
    private func pageInputRecent(at now: TimeInterval) -> Bool {
        guard let board else { return false }
        return pageInput.isRecent(at: now, refresh: board.refresh)
    }

    /// An input's dispatch ended; one to a Chromium page keeps the passes in the input class.
    private func notePageDispatch(_ target: InputTarget) {
        guard isRunning, target == .chromiumPage else { return }
        pageInput.dispatched(at: clock())
    }

    /// An input's dispatch ended (outside its dispatch scope). A pass held for it is re-armed for the
    /// next run loop pass; after input AppKit delivered to a Chromium page, a due pass is armed for the
    /// next run loop pass and runs whatever input is pending (its input router and wheel acks run
    /// inside the pump). During a pass (a nested run loop) the outer pass re-arms when it returns.
    private func inputDispatchEnded(_ target: InputTarget) {
        notePageDispatch(target)
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

    /// `reason`: the timer fire that runs this pass; nil for the quit path's drain. `workClass`: its
    /// board class, read when it was admitted (nil: read now, or no board).
    private func fire(for reason: LedgerReason? = nil, workClass: MainWorkClass? = nil) {
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
            if let keysOutsidePass { restoreKeys(keysOutsidePass) } // the nested loop is not the pump
            rearm()
            return
        }
        // This pass is the one any hold or Chromium input waited for.
        inputHoldDeadline = nil
        chromiumInputPass = false
        input?.holdEnded()
        let passClass = workClass ?? boardClass(at: started)
        // A page input dispatched during this pass (a nested run loop) waits for the next.
        pageInput.passBegan()
        earlyPassWatch.passBegan(serving: served, at: started)
        rearm()
        let interval = signposter.beginCEFPump(reasonCode: traceReason?.traceCode ?? 0)
        if let board, let passClass {
            board.budget.run(passClass, owner: board.owner) { runPass() }
        } else {
            runPass()
        }
        let elapsed = clock() - started
        let longRun = counters.recordWorkRun(elapsed: elapsed, timeSlice: timeSlice, metrics: signposter.metrics)
        signposter.endCEFPump(interval, longRun: longRun, elapsedMicros: UInt64(max(0, elapsed) * 1e6))
        if earlyPassWatch.passEnded(usedWholeSlice: longRun) { counters.earlyPasses += 1 }
        if input != nil { counters.passTimes.record(nanos: UInt64(max(0, elapsed) * 1e9)) }
        schedule.endWork()
        rearm()
    }

    /// One `CefDoMessageLoopWork`, with the CEF state key at `inPump` and `in_cef_pump` at 1, and the values
    /// before them put back after (Chrome's `ScopedCrashKeyString`, components/crash/core/common/crash_key.h).
    private func runPass() {
        let outside = (cefState: crashKeys?.value(.cefState), inCEFPump: trace.crashKey(.inCEFPump))
        keysOutsidePass = outside
        crashKeys?.set(.cefState, CrashKeySlots.CEFState.inPump.rawValue)
        trace.setCrashKey(.inCEFPump, 1)
        work()
        restoreKeys(outside)
        keysOutsidePass = nil
    }

    /// Puts the crash keys a pass set back to `outside`.
    private func restoreKeys(_ outside: (cefState: UInt64?, inCEFPump: UInt64)) {
        if let cefState = outside.cefState { crashKeys?.set(.cefState, cefState) }
        trace.setCrashKey(.inCEFPump, outside.inCEFPump)
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
