import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The one timer that drives the external message pump. The pump re-arms it
/// for each CEF request instead of creating timers, so a new request always
/// replaces the previous fire date.
protocol CEFPumpTimer: AnyObject {
    /// Called on the main thread when the timer fires.
    var onFire: (() -> Void)? { get set }
    /// True while ``onFire`` runs for a fire of a delayed arm that the main deadline queue already
    /// counted in the wakeup ledger (the pump then counts it no second time).
    var fireIsCountedByQueue: Bool { get }
    /// Fires once, `delay` seconds from now (0 = on the next run loop pass).
    /// `tolerance` lets the system coalesce the wakeup with others.
    func arm(after delay: TimeInterval, tolerance: TimeInterval)
    /// Cancels the pending fire, if any.
    func disarm()
    /// Stops for good: no fire after this.
    func invalidate()
}

extension CEFPumpTimer {
    var fireIsCountedByQueue: Bool { false }
}

/// The pump's fire dates on the main thread's one deadline queue (`MainWorkScheduler.wakeUps`), so a
/// Chromium delayed task and the cmux deadlines near it share one wake: Chrome's UI thread has one
/// delayed-work timer for every task queue (`MessagePumpCFRunLoopBase::delayed_work_timer_`,
/// base/message_loop/message_pump_apple.mm, fed by `WakeUpQueue`, base/task/sequence_manager/wake_up_queue.h).
///
/// A delayed arm is a `.flexibleNoSooner` queue entry, aligned to the queue's grid with its leeway
/// (Chromium's `kDefaultLeeway` and `AdjustDelayedRunTime`); that window replaces the pump's own
/// `tolerance`. The entry runs no CEF: it queues one main run-loop block that calls ``onFire``, so
/// `CefDoMessageLoopWork` runs after every cmux entry of the same fire, and a nested run loop inside a
/// CEF pass (a menu, a modal panel) holds no cmux deadline. An arm for now queues that block at once and
/// never waits for the queue's timer. A new arm, ``disarm()`` and ``invalidate()`` drop what the last
/// arm queued.
final class CEFWakeUpQueuePumpTimer: CEFPumpTimer {
    /// The ledger owner of the pump's queue entries (reason `deadline`): the pump's own owner.
    static let ledgerOwner = "CEFMessagePump"
    /// A delayed arm this close to the pending one keeps it: the pump re-arms for the same CEF request
    /// several times a pass, and its clock and the queue's are read microseconds apart.
    static let sameDeadline: UInt64 = 100_000
    /// Longer than any CEF request (CEF sends `int` milliseconds): keeps the ns arithmetic in range.
    static let longestDelay: TimeInterval = 1.0e6

    var onFire: (() -> Void)?
    private(set) var fireIsCountedByQueue = false

    private enum Pending {
        case none
        /// A queue entry for the delayed arm, due at `deadline` (uptime ns).
        case deadline(MainWakeUpQueue.Token, deadline: UInt64)
        /// A run-loop block is queued; `countedByQueue` when a queue fire queued it.
        case block(countedByQueue: Bool)
    }

    private let queue: MainWakeUpQueue
    private let uptime: () -> UInt64
    private let post: (@escaping @MainActor () -> Void) -> Void
    private var pending = Pending.none
    /// Bumped by every arm, disarm and fire, so a block or entry of an older arm does nothing.
    private var generation: UInt64 = 0
    private var invalidated = false

    /// - Parameters:
    ///   - queue: The main thread's one deadline queue (`MainWorkScheduler.wakeUps`).
    ///   - uptime: The queue's clock, `CLOCK_UPTIME_RAW` ns (tests pass the fake the queue reads).
    ///   - post: Queues a block on the main run loop and wakes it (tests drain the blocks by hand).
    init(
        queue: MainWakeUpQueue,
        uptime: @escaping () -> UInt64 = WakeupLedger.systemUptime,
        post: @escaping (@escaping @MainActor () -> Void) -> Void = { MainRunLoopBlock.perform($0) }
    ) {
        self.queue = queue
        self.uptime = uptime
        self.post = post
    }

    func arm(after delay: TimeInterval, tolerance: TimeInterval) {
        guard !invalidated else { return }
        guard delay > 0 else {
            if case .block = pending { return } // a queued block is already the next run loop pass
            drop()
            queueBlock(countedByQueue: false)
            return
        }
        let delayNanos = UInt64(min(delay, Self.longestDelay) * 1e9)
        let deadline = uptime() &+ delayNanos
        if case .deadline(_, deadline: let armed) = pending, Self.close(armed, deadline) { return }
        drop()
        let generation = generation
        let token = queue.insert(owner: Self.ledgerOwner, after: .nanoseconds(Int64(delayNanos)),
                                 policy: .flexibleNoSooner) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.queueBlock(countedByQueue: true)
        }
        pending = .deadline(token, deadline: deadline)
    }

    func disarm() {
        drop()
    }

    func invalidate() {
        drop()
        invalidated = true
        onFire = nil
    }

    /// Cancels the pending entry and makes every queued block and entry of earlier arms stale.
    private func drop() {
        if case .deadline(let token, deadline: _) = pending { queue.cancel(token) }
        pending = .none
        generation &+= 1
    }

    private func queueBlock(countedByQueue: Bool) {
        pending = .block(countedByQueue: countedByQueue)
        let generation = generation
        post { [weak self] in
            guard let self, self.generation == generation, case .block(countedByQueue: let counted) = self.pending else { return }
            self.pending = .none
            self.generation &+= 1
            self.fireIsCountedByQueue = counted
            self.onFire?()
            self.fireIsCountedByQueue = false
        }
    }

    private static func close(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        (lhs > rhs ? lhs - rhs : rhs - lhs) <= sameDeadline
    }
}
