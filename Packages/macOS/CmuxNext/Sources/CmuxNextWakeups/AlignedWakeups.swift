/// One wake per boundary bucket for main-thread deadlines (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E): a deadline is placed on a grid, and every deadline due by a boundary runs in that boundary's
/// one fire of ``MainWakeUpQueue``.
///
/// The three alignments are Chrome's:
/// - ``Alignment/flexible``, the default: no sooner than its time, snapped up to the next 8 ms tick
///   (32 ms in Energy Saver), with that leeway as the timer's tolerance (`kAlignWakeUps` and `kDefaultLeeway`,
///   base/task/task_features.h; `MessagePump::AdjustDelayedRunTime`, base/message_loop/message_pump.cc).
///   A delay of 1 s or more gets ``WakeLeeway``'s whole-second grid.
/// - ``Alignment/precise``: at its own instant with no tolerance, only below 36 ms; a longer one becomes
///   flexible (`kDefaultMaxPreciseDelay`, `MaybeOverrideDelayPolicy` in base/task/delay_policy.h).
/// - ``Alignment/hidden``: no sooner than its time, snapped up to the next whole uptime second, with up to
///   1 s of tolerance (a hidden frame's wake-ups, `WakeUpBudgetPool::GetNextAllowedWakeUp` in
///   third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc). A delay of
///   zero or less is not a timer and runs on the next fire, as Blink throttles only delayed tasks.
///
/// Every alignment shares the queue's one timer, so a hidden deadline that is already due also runs in an
/// earlier fire made for another deadline: it never adds a wake of its own then. The grid is
/// `CLOCK_UPTIME_RAW`, the same instants for every caller in the process.
///
/// `MainDeadline` chooses the alignment (``Alignment/hidden`` only while its node is hidden and not exempt
/// for media or capture); this type only places it. The one instance wraps the composition root's queue.
///
/// ```swift
/// let wakeups = AlignedWakeups(queue: mainWakeUpQueue)
/// let ticket = wakeups.schedule(owner: "Sidebar.hover", after: .milliseconds(300), alignment: .flexible) { show() }
/// wakeups.cancel(ticket)
/// ```
public struct AlignedWakeups: Sendable {
    /// How a deadline is placed on the timeline.
    public enum Alignment: Sendable, Hashable, CaseIterable {
        /// At its own instant with no tolerance, below 36 ms; flexible from 36 ms on.
        case precise
        /// No sooner than its time, snapped up to the queue's grid (8 ms; 1 s from a 1 s delay on).
        case flexible
        /// No sooner than its time, snapped up to the next whole second (a hidden node's timers).
        case hidden
    }

    /// A scheduled deadline; pass it to ``cancel(_:)``.
    public struct Ticket: Hashable, Sendable {
        let token: MainWakeUpQueue.Token
    }

    /// The hidden grid and its leeway (Blink's 1 s wake-up alignment of a hidden frame).
    public static let hiddenInterval: Duration = .seconds(1)

    private let queue: MainWakeUpQueue

    /// - Parameter queue: The main thread's one deadline timer.
    public init(queue: MainWakeUpQueue) {
        self.queue = queue
    }

    /// Deadlines waiting to run, of every user of the queue.
    public var pendingCount: Int { queue.count }

    /// Runs `action` once on the main thread, no sooner than `delay` from now, at the boundary `alignment`
    /// gives. Callable from any thread.
    ///
    /// - Parameters:
    ///   - owner: Who asked; the `WakeupLedger` owner of the deadline (reason `deadline`).
    ///   - delay: How long to wait at least (zero or less: the next fire).
    ///   - alignment: How the deadline is placed.
    ///   - action: Runs on the main actor in the boundary's fire; it should post its work, not do it.
    /// - Returns: The ticket that cancels it.
    @discardableResult
    public func schedule(owner: String, after delay: Duration, alignment: Alignment = .flexible,
                         _ action: @escaping MainWakeUpQueue.Action) -> Ticket {
        switch alignment {
        case .precise:
            Ticket(token: queue.insert(owner: owner, after: delay, policy: .precise, action))
        case .flexible:
            Ticket(token: queue.insert(owner: owner, after: delay, policy: .flexibleNoSooner, action))
        case .hidden:
            Ticket(token: queue.insert(owner: owner, after: delay, window: .hidden(delay: delay), action))
        }
    }

    /// Drops a pending deadline; false when it already ran or was cancelled. The queue's timer moves to the
    /// next deadline, or parks when this was the last one. Callable from any thread.
    @discardableResult
    public func cancel(_ ticket: Ticket) -> Bool {
        queue.cancel(ticket.token)
    }
}

extension WakeLeeway {
    /// The window of a hidden node's timer `delay` from now: no sooner than its deadline, fired at the
    /// first whole uptime second at or after it (``AlignedWakeups/hiddenInterval`` of grid and leeway).
    /// A delay of zero or less is due now and stays exact.
    public static func hidden(delay: Duration) -> WakeLeeway {
        guard delay > .zero else { return .window(delay: delay) }
        let interval = AlignedWakeups.hiddenInterval
        return WakeLeeway(delay: delay, policy: .flexibleNoSooner, leeway: interval, grid: interval)
    }
}
