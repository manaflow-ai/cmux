import Foundation

/// When the external message pump must call `CefDoMessageLoopWork` next.
/// Pure value logic; `CEFMessagePump` applies it to one timer.
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
nonisolated struct CEFPumpSchedule: Equatable, Sendable {
    /// CEF's `max_time_slice` for one `CefDoMessageLoopWork` call.
    static let timeSlice: TimeInterval = 0.010
    /// The first fork API whose `MessagePumpExternal` is demand-driven.
    static let demandDrivenForkAPI: Int32 = 7
    /// Leeway of a delayed request: Chromium's own default for delayed tasks
    /// (base's `kDefaultLeeway`, 8 ms), so the system can coalesce the wake
    /// with others (an idle browser asks about 1.7 times a second). Never more
    /// than a tenth of the delay; a request for "now" stays exact.
    static let delayedLeeway: TimeInterval = 0.008

    /// The next timer fire, in the clock's seconds.
    struct Wake: Equatable, Sendable {
        var deadline: TimeInterval
        var tolerance: TimeInterval
    }

    private(set) var isWorking = false
    /// Work that must run on the next run loop pass.
    private var immediate = false
    private var requestedDeadline: TimeInterval?
    /// Leeway of `requestedDeadline` (`delayedLeeway`, capped by its delay).
    private var requestedTolerance: TimeInterval = 0
    /// The earliest Chromium-thread request the gate kept (``CEFPumpCrossThreadGate``). It stays
    /// until a pass at or after it: a later CEF request does not replace it, since that request may
    /// be a stale one posted before the keep.
    private(set) var keptDeadline: TimeInterval?
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
        return Wake(deadline: deadline, tolerance: deadline == requestedDeadline ? requestedTolerance : Self.delayedLeeway)
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
        requestedTolerance = min(Self.delayedLeeway, delay / 10)
    }

    /// A Chromium thread's delayed request that the gate kept (``CEFPumpCrossThreadGate``): a pass
    /// runs no later than `deadline`, whatever CEF requests until then.
    mutating func requestNoLater(than deadline: TimeInterval) {
        keptDeadline = min(keptDeadline ?? .infinity, deadline)
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
}
