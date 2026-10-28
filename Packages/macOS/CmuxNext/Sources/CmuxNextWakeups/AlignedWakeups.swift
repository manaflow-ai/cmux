/// Places main-thread deadlines on ``MainWakeUpQueue``'s boundaries (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section E), so close deadlines share the queue's one wake.
///
/// The placements are the resolved form of `TimerAlignment`: `MainDeadline` maps
/// `.whenHidden(node)` to ``Placement/hidden`` while the node is hidden and not exempt for media,
/// and to ``Placement/flexible`` otherwise; this type only places. They are Chrome's:
/// - ``Placement/flexible``, the default: no sooner than its time, snapped up to the next 8 ms tick
///   (32 ms in Energy Saver), with that leeway (`kAlignWakeUps` and `kDefaultLeeway`,
///   base/task/task_features.h; `MessagePump::AdjustDelayedRunTime`, base/message_loop/message_pump.cc).
///   A delay of 1 s or more gets ``WakeLeeway``'s whole-second grid.
/// - ``Placement/precise``: at its own instant, only below 36 ms; a longer one becomes flexible
///   (`kDefaultMaxPreciseDelay`, `MaybeOverrideDelayPolicy` in base/task/delay_policy.h).
/// - ``Placement/hidden``: runs only in a fire at or after the whole uptime second at or after its time
///   (Blink's 1 s wake-up alignment of a hidden frame, whose throttled queue is fenced between wake-ups,
///   `WakeUpBudgetPool`, third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc).
///   An earlier fire made for a visible deadline does not run it. A delay of zero or less is not throttled
///   and runs on the next fire, as Blink throttles only delayed tasks.
///
/// Entries run in latest-time order, as in Chrome's `WakeUpQueue`: a visible entry runs in the first fire
/// where it and every visible entry with a smaller latest time are due, and a hidden one in the first fire
/// at or after its boundary. The queue arms its timer for the earliest fire date with the slack up to the
/// smallest latest time as the tolerance. The grid is `CLOCK_UPTIME_RAW`, the same instants for every
/// caller in the process.
///
/// ```swift
/// let wakeups = AlignedWakeups(queue: mainWakeUpQueue)
/// let ticket = wakeups.schedule(owner: "Sidebar.hover", after: .milliseconds(300), placement: .flexible) { show() }
/// wakeups.cancel(ticket)
/// ```
public struct AlignedWakeups: Sendable {
    /// Where a deadline goes on the timeline: the resolved form of `TimerAlignment`.
    public enum Placement: Sendable, Hashable, CaseIterable {
        /// At its own instant, below 36 ms; flexible from 36 ms on.
        case precise
        /// No sooner than its time, snapped up to the queue's grid (8 ms; 1 s from a 1 s delay on).
        case flexible
        /// `TimerAlignment.whenHidden(node)` while the node is hidden: only at or after its whole second.
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

    /// Runs `action` once on the main thread, no sooner than `delay` from now, where `placement` puts it.
    /// Callable from any thread.
    ///
    /// - Parameters:
    ///   - owner: Who asked; the `WakeupLedger` owner of the deadline (reason `deadline`).
    ///   - delay: How long to wait at least (zero or less: the next fire).
    ///   - placement: Where the deadline goes.
    ///   - file: The line that asked, named by the arm census in Debug and bench builds (leave the default).
    ///   - line: See `file`.
    ///   - action: Runs on the main actor in the boundary's fire; it should post its work, not do it.
    /// - Returns: The ticket that cancels it.
    @discardableResult
    public func schedule(owner: String, after delay: Duration, placement: Placement = .flexible,
                         file: StaticString = #fileID, line: UInt = #line,
                         _ action: @escaping MainWakeUpQueue.Action) -> Ticket {
        #if DEBUG || CMUX_BENCH_HOOKS
        // One record per deadline in the launch's arm census; its fire is the record's first.
        let action = Self.census(queue.ledger.armCensus, owner: owner, site: ArmCensus.Site(file: file, line: line), action)
        #endif
        switch placement {
        case .precise:
            return Ticket(token: queue.insert(owner: owner, after: delay, policy: .precise, action))
        case .flexible:
            return Ticket(token: queue.insert(owner: owner, after: delay, policy: .flexibleNoSooner, action))
        case .hidden:
            return Ticket(token: queue.insertHidden(owner: owner, after: delay, action))
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `action`, recording its first fire when `census` records the deadline's arm.
    private static func census(_ census: ArmCensus, owner: String, site: ArmCensus.Site,
                               _ action: @escaping MainWakeUpQueue.Action) -> MainWakeUpQueue.Action {
        guard let slot = census.armed(.mainDeadline, owner: owner, site: site) else { return action }
        return {
            census.fired(slot)
            action()
        }
    }
    #endif

    /// ``schedule(owner:after:placement:file:line:_:)`` for a deadline given as an instant on the queue's clock
    /// (uptime ns), so a deadline that moves to another placement keeps its due time. Callable from any
    /// thread.
    @discardableResult
    func schedule(owner: String, at deadline: UInt64, placement: Placement,
                  ledgerReason: MainWakeUpQueue.LedgerReason = .deadline,
                  _ action: @escaping MainWakeUpQueue.Action) -> Ticket {
        if placement == .hidden { return Ticket(token: queue.insertHidden(owner: owner, at: deadline, action)) }
        let window = self.window(placement, deadline: deadline)
        return Ticket(token: queue.insert(owner: owner, at: deadline, window: window, ledgerReason: ledgerReason, action))
    }

    /// The window `placement` gives a deadline at `deadline` (uptime ns), from the time left now: the one
    /// ``schedule(owner:at:placement:_:)`` places it in, whose ``WakeLeeway/fireTime(deadline:)`` is when
    /// it fires alone.
    func window(_ placement: Placement, deadline: UInt64) -> WakeLeeway {
        let now = queue.now
        let delay: Duration = deadline > now ? .nanoseconds(Int64(clamping: deadline - now)) : .zero
        switch placement {
        case .precise: return .window(delay: delay, policy: .precise, alignment: queue.alignment)
        case .flexible: return .window(delay: delay, policy: .flexibleNoSooner, alignment: queue.alignment)
        case .hidden: return .hidden(delay: delay)
        }
    }

    /// Now on the queue's clock (uptime ns).
    var now: UInt64 { queue.now }

    /// The uptime the queue's timer is armed for (ns), for every user of the queue; nil while it is parked.
    var nextFireDate: UInt64? { queue.armedDate }

    /// The queue itself, for an owner that takes its waits' timeouts from the same deadline placer
    /// (``MainDeadlineScheduler/wakeUpQueue``).
    var mainQueue: MainWakeUpQueue { queue }

    /// The queue's ledger, for owners that run in a fire under another owner's entry.
    var ledger: WakeupLedger { queue.ledger }

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
