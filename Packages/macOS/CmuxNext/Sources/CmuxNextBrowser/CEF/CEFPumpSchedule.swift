import Foundation

/// When the external message pump must call `CefDoMessageLoopWork` next.
/// Pure value logic; `CEFMessagePump` applies it to one timer.
///
/// CEF asks for work through `OnScheduleMessagePumpWork(delay_ms)`: 0 means
/// "now", a delay is its earliest delayed task (CEF sends it only when no
/// work is pending, so it replaces an earlier delayed request).
///
/// Fork API 7 and later (cef-154.0.28-cmux.7) is demand-driven: its
/// `MessagePumpExternal` asks for "now" when its slice ends with work left
/// and reports its next delayed task, so the pump uses `.none` and wakes
/// only when CEF asks. Older forks have two gaps in `MessagePumpExternal`
/// (libcef/browser/browser_message_loop.cc) that need `standard`:
/// - `CefDoMessageLoopWork` stops after a 10 ms time slice even when
///   immediate work remains, and Chromium does not ask again for it
///   (`WorkDeduplicator` believes the pump will call back). With the
///   follow-ups, a pass that used the whole slice runs again at once.
/// - A delayed task posted while `CefDoMessageLoopWork` runs is reported
///   only in the pass's return value, which CEF drops. So after a pass the
///   pump follows up with a few one-shot wakes: 1/30 s later (cefclient's
///   interval), then gaps that double, the last one 1 s, about 2 s in all.
///   Any request starts the follow-ups again. Then the pump sleeps until CEF
///   asks: an idle Chromium costs no wakeups (no polling). A delayed task
///   posted during activity runs late by at most about its own delay; one
///   due more than about 2 s after the last activity waits for CEF's next
///   request.
nonisolated struct CEFPumpSchedule: Equatable, Sendable {
    enum SafetyNet: Equatable, Sendable {
        /// Wake only when CEF asks.
        case none
        /// Wake `first` seconds after a pass, then after gaps that double
        /// while no request arrives; the chain ends after a gap of `last`.
        case followUps(first: TimeInterval, last: TimeInterval)
    }

    /// CEF's `max_time_slice` for one `CefDoMessageLoopWork` call.
    static let timeSlice: TimeInterval = 0.010
    static let standard = SafetyNet.followUps(first: 1.0 / 30.0, last: 1.0)
    /// The first fork API whose `MessagePumpExternal` is demand-driven: it
    /// asks for "now" when its slice ends with work left and reports its
    /// next delayed task (cef-154.0.28-cmux.7).
    static let demandDrivenForkAPI: Int32 = 7

    /// `.none` with a demand-driven fork; older pins keep the follow-ups.
    static func safetyNet(forkAPIVersion: Int32) -> SafetyNet {
        forkAPIVersion >= demandDrivenForkAPI ? .none : standard
    }
    /// Share of a safety-net interval the system may add to coalesce wakeups.
    static let safetyNetTolerance = 0.1

    /// The next timer fire, in the clock's seconds.
    struct Wake: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// CEF (or cmux) asked for work, or a pass must continue.
            case scheduled
            /// A follow-up wake after a pass (the safety net).
            case fallback
        }

        var deadline: TimeInterval
        var tolerance: TimeInterval
        var reason: Reason = .scheduled
    }

    let safetyNet: SafetyNet
    private(set) var isWorking = false
    /// Work that must run on the next run loop pass.
    private var immediate = false
    private var requestedDeadline: TimeInterval?
    private var safetyNetDeadline: TimeInterval?
    /// The interval of the pending safety-net wake (nil when none is armed).
    private(set) var armedSafetyNetInterval: TimeInterval?
    /// The gap of the next follow-up wake; nil when the chain has ended.
    private var nextFollowUp: TimeInterval?
    /// A timer fire arrived while a pass was running (a nested run loop).
    private var reentered = false

    init(safetyNet: SafetyNet = standard) {
        self.safetyNet = safetyNet
        nextFollowUp = Self.firstFollowUp(of: safetyNet)
    }

    /// The next wake, or nil when nothing needs the pump. Always nil while a
    /// pass runs: a nested run loop must not spin on the timer, and the pass
    /// decides the next wake when it returns.
    var nextWake: Wake? {
        guard !isWorking else { return nil }
        if immediate { return Wake(deadline: -.infinity, tolerance: 0) }
        switch (requestedDeadline, safetyNetDeadline) {
        case let (requested?, net?) where net < requested:
            return Wake(deadline: net, tolerance: safetyNetTolerance, reason: .fallback)
        case let (requested?, _):
            return Wake(deadline: requested, tolerance: 0)
        case let (nil, net?):
            return Wake(deadline: net, tolerance: safetyNetTolerance, reason: .fallback)
        case (nil, nil):
            return nil
        }
    }

    /// An `OnScheduleMessagePumpWork(delay_ms)` request (or cmux's own "pump
    /// now" with 0).
    mutating func request(milliseconds: Int64, now: TimeInterval) {
        nextFollowUp = Self.firstFollowUp(of: safetyNet)
        if milliseconds <= 0 {
            immediate = true
        } else {
            // CEF's earliest delayed task, including those the last pass
            // posted: it replaces the earlier request and the safety net.
            requestedDeadline = now + TimeInterval(milliseconds) / 1_000
            safetyNetDeadline = nil
            armedSafetyNetInterval = nil
        }
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
        safetyNetDeadline = nil
        armedSafetyNetInterval = nil
        // The timer and this clock differ by microseconds: a request due
        // within a millisecond is served by this pass.
        if let requested = requestedDeadline, requested <= now + 0.001 { requestedDeadline = nil }
        return true
    }

    /// Call after `CefDoMessageLoopWork` returned, `elapsed` seconds after it
    /// began.
    mutating func endWork(now: TimeInterval, elapsed: TimeInterval) {
        isWorking = false
        // A demand-driven fork asks again itself when its slice ends.
        let sliceMayHaveCutWork = safetyNet != .none && elapsed >= Self.timeSlice
        if reentered || sliceMayHaveCutWork {
            immediate = true
            nextFollowUp = Self.firstFollowUp(of: safetyNet)
        }
        reentered = false
        guard case let .followUps(_, last) = safetyNet, let gap = nextFollowUp else { return }
        safetyNetDeadline = now + gap
        armedSafetyNetInterval = gap
        nextFollowUp = gap >= last ? nil : min(gap * 2, last)
    }

    private var safetyNetTolerance: TimeInterval {
        (armedSafetyNetInterval ?? 0) * Self.safetyNetTolerance
    }

    private static func firstFollowUp(of safetyNet: SafetyNet) -> TimeInterval? {
        if case let .followUps(first, _) = safetyNet { return first }
        return nil
    }
}
