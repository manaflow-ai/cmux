import CmuxNextCompat
import CmuxNextWakeups

/// Decides, on the thread that calls it, whether a CEF `OnScheduleMessagePumpWork` request from a
/// Chromium thread must wake the main thread (``CEFMessagePump``).
///
/// Every off-main request posted a block to the main run loop and woke it, even a delayed request
/// whose deadline came after the pump's armed fire: the main thread woke only to keep the earlier
/// deadline. Such a request is dropped here, with no wake: the armed pass runs first, and the
/// pass makes CEF report its next delayed task again. The rule keeps every other request:
///
/// - an immediate request (0 ms) always goes through;
/// - with no armed deadline published (none armed, an immediate pass pending, or a pass running:
///   the pump publishes none before it calls `CefDoMessageLoopWork`), it goes through;
/// - with an armed deadline that is already due, it goes through (the timer may be firing now);
/// - a delayed request is dropped only when the armed deadline is still in the future and not
///   later than the request's own deadline.
///
/// A kept cross-thread request is one main wake, recorded in the wakeup ledger (owner
/// `CEFMessagePump`, reason `cross-thread request`); a dropped one is a counter (``dropped``), not
/// a wake.
nonisolated final class CEFPumpCrossThreadGate: Sendable {
    /// The armed fire's deadline in `CLOCK_UPTIME_RAW` nanoseconds; 0 when none is published.
    private let armedNanos = Atomic<UInt64>(0)
    private let droppedRequests = Atomic<UInt64>(0)
    private let ledger: WakeupLedger

    /// - Parameter ledger: Where kept cross-thread requests are counted as main wakes.
    init(ledger: WakeupLedger = .shared) {
        self.ledger = ledger
    }

    /// Main thread: the armed fire's deadline (uptime nanoseconds), or nil when none may be
    /// trusted (nothing armed, an immediate pass pending, a pass about to run or running).
    func publish(deadlineNanos: UInt64?) {
        armedNanos.store(deadlineNanos.map { max($0, 1) } ?? 0, ordering: .releasing)
    }

    /// Any thread: whether a request for work `delayMilliseconds` from `nowNanos` must reach the
    /// main thread. Records a kept request in the ledger and counts a dropped one.
    func admit(delayMilliseconds: Int64, nowNanos: UInt64) -> Bool {
        if delayMilliseconds > 0 {
            let armed = armedNanos.load(ordering: .acquiring)
            let requested = nowNanos &+ UInt64(delayMilliseconds) &* 1_000_000
            if armed != 0, armed > nowNanos, armed <= requested {
                droppedRequests.add(1, ordering: .relaxed)
                return false
            }
        }
        ledger.record("CEFMessagePump", reason: "cross-thread request")
        return true
    }

    /// Delayed cross-thread requests dropped because an earlier fire was armed.
    var dropped: UInt64 { droppedRequests.load(ordering: .relaxed) }
}
