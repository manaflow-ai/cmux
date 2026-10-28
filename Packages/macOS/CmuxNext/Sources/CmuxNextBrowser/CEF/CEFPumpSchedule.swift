import CmuxNextWakeups
import Foundation

/// When the external message pump must call `CefDoMessageLoopWork` next.
/// Pure value logic; `CEFMessagePump` applies it to one timer. In process only: in host mode the
/// Chromium Host pumps Chromium and the app schedules no `CefDoMessageLoopWork`.
///
/// CEF asks for work through `OnScheduleMessagePumpWork(delay_ms)`: 0 means
/// "now", a delay is its earliest delayed task (CEF sends it only when no
/// work is pending, so it replaces an earlier delayed request). The pump is
/// demand-driven, as Chromium's own `MessagePumpCFRunLoopBase`
/// (base/message_loop/message_pump_apple.mm) wakes only for work it was
/// told about: it wakes only when CEF asks, and an idle Chromium costs no
/// wakeups. Fork API 7 (cef-154.0.28-cmux.7) made `MessagePumpExternal`
/// ask for "now" when its slice ends with work left and report its next
/// delayed task; an older fork still runs, demand-only (`CEFRuntime` logs it).
///
/// A fork with `cmux_set_on_schedule_delayed` (p14-energy-046) sends delayed work as an absolute
/// run time with Chromium's leeway and policy instead (``request(runTimeNanos:leewayNanos:precise:)``),
/// as `MessagePumpCFRunLoopBase::ScheduleDelayedWork` arms its timer at `delayed_run_time` with
/// tolerance `next_work_info.leeway` under `kTimerSlackMac`. The whole-millisecond request truncated
/// the delay against a stale `recent_now`: a 7.9 ms task fired at 7 ms, found nothing due, and the
/// re-ask truncated to 0, "now" (``CEFPumpStats/earlyPasses``). An older fork keeps that path.
nonisolated struct CEFPumpSchedule: Equatable, Sendable {
    /// CEF's `max_time_slice` for one `CefDoMessageLoopWork` call on a fork below
    /// ``pumpTimeSliceSwitchForkAPI``, which may ignore `--cmux-pump-time-slice-us`.
    static let timeSlice: TimeInterval = 0.010
    /// The first fork API every build of which honours `--cmux-pump-time-slice-us` (cef-cmux 066b083f,
    /// which kept API 24): API 26 (layer hosting) is the first API made on top of that commit. API 24 and 25 builds exist with and without it (cmux.28 and the API 25 keychain
    /// line lack it), so they are judged by CEF's 10 ms. cmux always passes the switch, so the fork's own
    /// default (2 ms from manaflow-ai/cef cp/p14-energy-037, in the p14-energy-136 bundle) changes nothing
    /// here. The same number as `CEFLayerHosting.forkAPI`, which is main-actor isolated.
    static let pumpTimeSliceSwitchForkAPI: Int32 = 26
    /// The first fork API whose `MessagePumpExternal` is demand-driven.
    static let demandDrivenForkAPI: Int32 = 7

    /// The longest one `CefDoMessageLoopWork` call runs ready work on a fork of `forkAPI` between `DoWork`
    /// batches before it returns and asks for "now": the switch's 2 ms
    /// (``CEFSwitches/pumpTimeSliceMicroseconds``) from ``pumpTimeSliceSwitchForkAPI``, CEF's 10 ms below
    /// it. A pass that runs this long may have left work.
    static func timeSlice(forkAPI: Int32) -> TimeInterval {
        forkAPI >= pumpTimeSliceSwitchForkAPI ? TimeInterval(CEFSwitches.pumpTimeSliceMicroseconds) / 1_000_000 : timeSlice
    }
    /// Leeway of a whole-millisecond delayed request: Chromium's own default for delayed tasks
    /// (base's `kDefaultLeeway`, 8 ms), so the system can coalesce the wake with others (an idle
    /// browser asks about 1.7 times a second). Never more than a tenth of the delay; a request for
    /// "now" stays exact.
    static let delayedLeeway: TimeInterval = 0.008
    /// A whole-millisecond request shorter than this is exact: it carries no policy, so it is treated
    /// as a precise task (`DelayPolicy.maxPreciseDelay`, Chrome's `kDefaultMaxPreciseDelay`).
    static let exactBelow: TimeInterval = {
        let (seconds, attoseconds) = DelayPolicy.maxPreciseDelay.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }()

    /// The class a pass runs in on the main-thread task board (``CEFPumpBoard``, p06-scheduler-048):
    /// input while a page has the keyboard or its ack of a page input may still be due
    /// (``RecentPageInput``; Chromium's input router runs inside `CefDoMessageLoopWork`), frame
    /// otherwise. Never a budgeted class and never by visibility: Chromium's one UI thread serves every
    /// page, a hidden tab's CDP round trip included, as Chrome's browser UI thread runs input at
    /// USER_BLOCKING and its other work unbudgeted (content/browser/scheduler/browser_task_queues.cc).
    static func workClass(pageHasFocus: Bool, pageInputRecent: Bool) -> MainWorkClass {
        pageHasFocus || pageInputRecent ? .input : .frame
    }

    /// The last input AppKit delivered to a Chromium page, while its ack may still be due. The pump
    /// sees no ack: the renderer's comes back through the IO thread, and a later pass handles it after
    /// an `OnScheduleMessagePumpWork` (content/browser/renderer_host/input/input_router_impl.cc; the
    /// wheel queue of components/input/mouse_wheel_event_queue.cc sends the next event only then). So
    /// an input counts until a pass began after it and one refresh passed since its dispatch ended.
    nonisolated struct RecentPageInput: Equatable, Sendable {
        /// When the last page input's dispatch ended, in the pump's clock (nil: none since start).
        private var dispatchedAt: TimeInterval?
        /// A pass began after it.
        private var passSince = false

        init() {}

        /// An input's dispatch to a page ended at `now` (a pass running then does not count).
        mutating func dispatched(at now: TimeInterval) {
            dispatchedAt = now
            passSince = false
        }

        /// A pass begins.
        mutating func passBegan() {
            passSince = true
        }

        /// Whether a pass at `now` may still be the one that handles that input's ack.
        func isRecent(at now: TimeInterval, refresh: TimeInterval) -> Bool {
            guard let dispatchedAt else { return false }
            return !passSince || now < dispatchedAt + refresh
        }
    }

    /// The next timer fire, in the clock's seconds.
    struct Wake: Equatable, Sendable {
        var deadline: TimeInterval
        /// How late after `deadline` the fire may come; 0 is exact. The timer uses it as is.
        var tolerance: TimeInterval
    }

    private(set) var isWorking = false
    /// Work that must run on the next run loop pass.
    private var immediate = false
    private var requestedDeadline: TimeInterval?
    /// Leeway of `requestedDeadline`: Chromium's on the absolute path, ``tolerance(ofDelay:)`` on the
    /// whole-millisecond one.
    private var requestedTolerance: TimeInterval = 0
    /// The earliest Chromium-thread request the gate kept (``CEFPumpCrossThreadGate``). It stays
    /// until a pass at or after it: a later CEF request does not replace it, since that request may
    /// be a stale one posted before the keep.
    private(set) var keptDeadline: TimeInterval?
    /// Leeway of `keptDeadline`: the gate keeps no policy, so ``tolerance(ofDelay:)`` of its delay.
    private var keptTolerance: TimeInterval = 0
    /// A timer fire arrived while a pass was running (a nested run loop).
    private var reentered = false
    /// The next pass runs a fire a nested run loop deferred (set when its pass ended, cleared when the next begins).
    private(set) var servesDeferredFire = false

    /// The next wake, or nil when nothing needs the pump. Always nil while a
    /// pass runs: a nested run loop must not spin on the timer, and the pass
    /// decides the next wake when it returns.
    var nextWake: Wake? {
        guard !isWorking else { return nil }
        if immediate { return Wake(deadline: -.infinity, tolerance: 0) }
        guard let deadline = [requestedDeadline, keptDeadline].compactMap({ $0 }).min() else { return nil }
        return Wake(deadline: deadline, tolerance: deadline == requestedDeadline ? requestedTolerance : keptTolerance)
    }

    /// An `OnScheduleMessagePumpWork(delay_ms)` request (or cmux's own "pump
    /// now" with 0). A delay is CEF's earliest delayed task, including those
    /// the last pass posted: it replaces the earlier request.
    mutating func request(milliseconds: Int64, now: TimeInterval) {
        guard milliseconds > 0 else {
            immediate = true
            return
        }
        let delay = TimeInterval(milliseconds) / 1_000
        requestedDeadline = now + delay
        requestedTolerance = Self.tolerance(ofDelay: delay)
    }

    /// A fork `cmux_on_schedule_delayed` request: CEF's earliest delayed work may run from
    /// `runTimeNanos` (`CLOCK_UPTIME_RAW` ns, Chromium's `TimeTicks`: this clock's seconds times 1e9;
    /// `Int64.max` for none) until `leewayNanos` after it. It replaces the earlier delayed request, as a
    /// whole-millisecond one does, and is never "now": a run time that has passed is due at once.
    /// Chromium's leeway is the tolerance as is, zero when `precise`: the request carries its policy.
    mutating func request(runTimeNanos: Int64, leewayNanos: Int64, precise: Bool) {
        guard let deadline = Self.runTime(nanos: runTimeNanos) else {
            requestedDeadline = nil
            requestedTolerance = 0
            return
        }
        requestedDeadline = deadline
        requestedTolerance = precise ? 0 : TimeInterval(max(0, leewayNanos)) / 1e9
    }

    /// A Chromium thread's delayed request that the gate kept (``CEFPumpCrossThreadGate``): a pass
    /// runs no later than `deadline`, whatever CEF requests until then.
    mutating func requestNoLater(than deadline: TimeInterval, now: TimeInterval) {
        guard deadline < (keptDeadline ?? .infinity) else { return }
        keptDeadline = deadline
        keptTolerance = Self.tolerance(ofDelay: deadline - now)
    }

    /// Call before `CefDoMessageLoopWork`. Returns false when a pass is
    /// already running (the timer fired in a nested run loop): do not call
    /// CEF; the outer pass runs the pump again when it returns.
    mutating func beginWork(now: TimeInterval) -> Bool {
        guard !isWorking else {
            reentered = true
            return false
        }
        isWorking = true
        reentered = false
        immediate = false
        servesDeferredFire = false
        // The timer and this clock differ by microseconds: a request due
        // within a millisecond is served by this pass.
        if let requested = requestedDeadline, requested <= now + 0.001 { requestedDeadline = nil }
        if let kept = keptDeadline, kept <= now + 0.001 { keptDeadline = nil }
        return true
    }

    /// Call after `CefDoMessageLoopWork` returned. A fire deferred by a
    /// nested run loop runs on the next run loop pass.
    mutating func endWork() {
        isWorking = false
        if reentered { immediate = true }
        servesDeferredFire = reentered
        reentered = false
    }

    /// The tolerance of a delayed request that carries no policy (a whole-millisecond one, or one the
    /// gate kept): exact below ``exactBelow``, otherwise ``delayedLeeway`` and at most a tenth of `delay`.
    static func tolerance(ofDelay delay: TimeInterval) -> TimeInterval {
        delay < exactBelow ? 0 : min(delayedLeeway, delay / 10)
    }

    /// A fork run time in this clock's seconds; nil for `Int64.max`, no delayed work. A negative one
    /// (never sent) is due at once.
    static func runTime(nanos: Int64) -> TimeInterval? {
        nanos == .max ? nil : TimeInterval(max(0, nanos)) / 1e9
    }

    /// A fork run time as the gate's uptime nanoseconds; nil for `Int64.max`, no delayed work.
    static func runTimeNanos(_ nanos: Int64) -> UInt64? {
        nanos == .max ? nil : UInt64(max(0, nanos))
    }
}
