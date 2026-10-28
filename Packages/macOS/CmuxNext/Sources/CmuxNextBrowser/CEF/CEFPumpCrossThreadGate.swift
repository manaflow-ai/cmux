import CmuxNextCompat
import CmuxNextWakeups

/// Decides, on the thread that calls it, whether a CEF `OnScheduleMessagePumpWork` request from a
/// Chromium thread must wake the main thread (``CEFMessagePump``).
///
/// Every off-main request posted a block to the main run loop and woke it, even a delayed request
/// whose deadline came after the pump's armed fire: the main thread woke only to keep the earlier
/// deadline. Such a request is now kept here with no wake, and the main thread merges it into its
/// schedule the next time it touches the pump (``take()``: before every pass and every re-arm),
/// so it is never lost, whatever CEF reports after the pass, and a stale block that moves the
/// armed fire later (a request posted before the drop but run after it) cannot strand it.
///
/// - An immediate request (0 ms) always goes through.
/// - With no armed deadline published (none armed, an immediate pass pending, a pass running, a
///   re-arm in progress, or an old fork whose pump has a safety net), it goes through.
/// - With an armed deadline already due, it goes through (the timer may be firing now).
/// - A delayed request is kept, with no wake, only while the armed deadline is in the future and
///   not later than the request's own.
///
/// The decision and the main thread's ``take()`` hold one lock, so a request is either merged by
/// the next take or decided against the deadline that take publishes; none falls between them.
/// A request that goes through is one main wake, recorded in the wakeup ledger (owner
/// `CEFMessagePump`, reason `cross-thread request`); a kept one is a counter (``kept``).
nonisolated final class CEFPumpCrossThreadGate: Sendable {
    private struct State {
        /// The armed fire's deadline, `CLOCK_UPTIME_RAW` nanoseconds; nil when none may be trusted.
        var armed: UInt64?
        /// The earliest deadline of the requests kept since the last ``take()``.
        var earliestKept: UInt64?
    }

    // Lock carve-out (CLAUDE.md): a synchronous compare-and-record called from Chromium threads
    // inside a C callback; an actor would add a hop and a wake, the thing this type removes.
    private let state = Mutex(State())
    private let keptRequests = Atomic<UInt64>(0)
    private let ledger: WakeupLedger

    /// - Parameter ledger: Where requests that wake the main thread are counted.
    init(ledger: WakeupLedger = .shared) {
        self.ledger = ledger
    }

    /// Main thread, before it changes the pump's schedule: stops keeping requests (none is
    /// published until ``publish(deadlineNanos:)``) and returns the earliest deadline of those
    /// kept since the last take, which the caller merges into its schedule.
    func take() -> UInt64? {
        state.withLock { state in
            state.armed = nil
            defer { state.earliestKept = nil }
            return state.earliestKept
        }
    }

    /// Main thread, after it armed the pump's timer: the armed fire's deadline (uptime
    /// nanoseconds), or nil to keep no request (nothing armed, an immediate pass, an old fork).
    func publish(deadlineNanos: UInt64?) {
        state.withLock { $0.armed = deadlineNanos }
    }

    /// Any thread: whether a request for work `delayMilliseconds` from `nowNanos` must wake the
    /// main thread. A request that does not is kept for the next ``take()``.
    func admit(delayMilliseconds: Int64, nowNanos: UInt64) -> Bool {
        if delayMilliseconds > 0 {
            let requested = nowNanos &+ UInt64(delayMilliseconds) &* 1_000_000
            let kept = state.withLock { state -> Bool in
                guard let armed = state.armed, armed > nowNanos, armed <= requested else { return false }
                state.earliestKept = min(state.earliestKept ?? .max, requested)
                return true
            }
            if kept {
                keptRequests.add(1, ordering: .relaxed)
                return false
            }
        }
        ledger.record("CEFMessagePump", reason: "cross-thread request")
        return true
    }

    /// Delayed cross-thread requests kept with no main wake because an earlier fire was armed.
    var kept: UInt64 { keptRequests.load(ordering: .relaxed) }
}
