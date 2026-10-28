/// Places ``MainDeadline``s on the main thread's one ``MainWakeUpQueue`` through ``AlignedWakeups``, keeps each hidden
/// node's wake-up budget, and is the next-fire registry (plans/cmux-next/chrome-parity/p06-scheduler.md, section E
/// and tasks 011, 012b).
///
/// Chromium keeps every delayed task of a thread in one wake-up queue and sleeps once, until the earliest
/// (`WakeUpQueue`, base/task/sequence_manager/wake_up_queue.h). Here that queue is ``MainWakeUpQueue``: a
/// ``MainDeadline`` is one of its entries, placed precise, flexible or hidden, so it shares a wake with every other
/// main-thread deadline on the same `CLOCK_UPTIME_RAW` grid. A wake hands the deadline to its ``MainDeadline``, which
/// posts its action on ``work`` in its class: the wake itself runs no deadline's work.
///
/// A repeating deadline hidden 5 minutes goes to its node's budget pool instead (Blink's `WakeUpBudgetPool`,
/// third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc): one heap of the node's
/// such deadlines with one queue entry, armed for ``TimerAlignment/intensiveFire(due:lastWake:)`` of its earliest.
/// The pool's wake runs every deadline of the node due by then and arms again from that wake, as
/// `WakeUpBudgetPool::OnWakeUp` and `UpdateStateForAllThrottledQueues` re-evaluate every queue of the pool, so a node
/// with several repeating deadlines still wakes once a minute.
///
/// The registry side: ``nextFire`` is the time left until the queue's next fire and ``nextFireNanos`` that instant
/// in uptime nanoseconds, for every user of the queue. They are read when needed, as Blink's `IdleHelper` reads its
/// thread's next delayed run time when it starts a long idle period.
///
/// The composition root makes one on its ``MainWorkScheduler``, whose ``MainWorkScheduler/wakeUps`` is the queue, and
/// passes it to every ``MainDeadline``:
///
/// ```swift
/// let deadlines = MainDeadlineScheduler(work: mainWork)
/// let refresh = MainDeadline(owner: "Cloud.poll", workClass: .background, alignment: .whenHidden(window),
///                            scheduler: deadlines)
/// refresh.start(every: .seconds(30)) { cloud.poll() }
/// ```
@MainActor
public final class MainDeadlineScheduler {
    /// Where deadline actions are posted, each in its deadline's class.
    public let work: MainWorkScheduler

    private let wakeups: AlignedWakeups
    /// Each hidden node's wake-up budget pool, Blink's per-page `WakeUpBudgetPool`.
    private var pools: [ObjectIdentifier: Pool] = [:]
    private var nextID: UInt64 = 0
    /// The pool count at which pools of released nodes, or empty ones with no wake in the last minute, are
    /// dropped; doubled after each pass.
    private var compactAt = 16

    /// Where a planned deadline sits, for ``remove(_:)``.
    enum Handle {
        /// An entry of the queue.
        case queued(AlignedWakeups.Ticket)
        /// An entry of a node's budget pool.
        case pooled(node: ObjectIdentifier, id: UInt64)
    }

    private struct Pool {
        weak var node: VisibilityNode?
        /// The pool's last wake (uptime ns); nil when it had none.
        var lastWake: UInt64?
        /// The node's intensive deadlines, by due instant (exact windows: earliest and latest are the due time).
        var entries = MainWakeUpHeap<Member>()
        /// The pool's entry on the queue: its ticket, its fire and the owner the queue records for it.
        var armed: (ticket: AlignedWakeups.Ticket, fire: UInt64, owner: String)?
    }

    private struct Member {
        weak var deadline: MainDeadline?
        let generation: UInt64
    }

    /// - Parameter work: The app's one main-thread scheduler: deadline actions are posted on it, and its
    ///   ``MainWorkScheduler/wakeUps`` is the queue the wakes go on.
    public convenience init(work: MainWorkScheduler) {
        self.init(work: work, queue: work.wakeUps)
    }

    /// The seam initializer: tests pass a queue on a fake timer. The queue's clock is the uptime every deadline and
    /// every hidden node's ``VisibilityNode/hiddenSince`` are read on (the app: `CLOCK_UPTIME_RAW` for both).
    init(work: MainWorkScheduler, queue: MainWakeUpQueue) {
        self.work = work
        wakeups = AlignedWakeups(queue: queue)
    }

    /// The time left until the queue's next fire (zero once it is due); nil when nothing is pending.
    public var nextFire: Duration? {
        guard let date = wakeups.nextFireDate else { return nil }
        let now = wakeups.now
        return date > now ? .nanoseconds(Int64(clamping: date - now)) : .zero
    }

    /// The queue's next fire in `CLOCK_UPTIME_RAW` nanoseconds; nil when nothing is pending.
    public var nextFireNanos: UInt64? { wakeups.nextFireDate }

    /// Now on the queue's clock: an owner that keeps its own due times (``MainDeadline/schedule(after:_:)`` takes a
    /// delay) reads them here, so its times and the wakes share one clock.
    public var uptime: Duration { .nanoseconds(Int64(clamping: now)) }

    // MARK: MainDeadline's side

    /// Now, on the queue's clock (uptime ns).
    var now: UInt64 { wakeups.now }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The queue's ledger's arm census, which each deadline tells of its launch arms.
    var armCensus: ArmCensus { wakeups.ledger.armCensus }
    #endif

    /// The rule `alignment` gives a deadline due at `due` now.
    func rule(_ alignment: TimerAlignment, due: UInt64, repeating: Bool) -> TimerAlignment.Wake.Rule {
        let now = self.now
        let delay: Duration = due > now ? .nanoseconds(Int64(clamping: due - now)) : .zero
        return alignment.rule(delay: delay, repeating: repeating, uptime: .nanoseconds(Int64(clamping: now)))
    }

    /// Places `deadline`'s wake for `due` under `rule`: at its wake, ``MainDeadline/wakeDidFire(_:)`` gets
    /// `generation`.
    func place(_ deadline: MainDeadline, generation: UInt64, due: UInt64, rule: TimerAlignment.Wake.Rule) -> Handle {
        if rule == .intensive, let node = deadline.alignment.node {
            return pool(deadline, node: node, generation: generation, due: due)
        }
        let placement = rule.placement ?? .hidden
        let ticket = wakeups.schedule(owner: deadline.owner, at: due, placement: placement) { [weak deadline] in
            deadline?.wakeDidFire(generation)
        }
        return .queued(ticket)
    }

    /// Where a deadline placed with `handle` for `due` under `rule` fires if nothing else moves its wake.
    func wake(_ handle: Handle, due: UInt64, rule: TimerAlignment.Wake.Rule) -> TimerAlignment.Wake {
        guard let placement = rule.placement else {
            guard case .pooled(let key, _) = handle, let pool = pools[key] else {
                return TimerAlignment.Wake(rule: rule, due: due, fire: due, tolerance: .zero)
            }
            var fire = TimerAlignment.intensiveFire(due: due, lastWake: pool.lastWake)
            if let armed = pool.armed, due <= armed.fire { fire = armed.fire }
            return TimerAlignment.Wake(rule: rule, due: due, fire: fire, tolerance: AlignedWakeups.hiddenInterval)
        }
        let window = wakeups.window(placement, deadline: due)
        return TimerAlignment.Wake(rule: rule, due: due, fire: window.fireTime(deadline: due), tolerance: window.leeway)
    }

    /// Drops a planned wake; the queue's timer follows the new earliest, or parks.
    func remove(_ handle: Handle) {
        switch handle {
        case .queued(let ticket):
            wakeups.cancel(ticket)
        case .pooled(let key, let id):
            guard pools[key]?.entries.remove(id: id) != nil else { return }
            rearm(key)
        }
    }

    // MARK: Budget pools

    private func pool(_ deadline: MainDeadline, node: VisibilityNode, generation: UInt64, due: UInt64) -> Handle {
        let key = ObjectIdentifier(node)
        if pools[key]?.node !== node {
            if pools.count >= compactAt { compactPools() }
            pools[key] = Pool(node: node)
        }
        nextID &+= 1
        let member = MainWakeUpHeap<Member>.Entry(
            id: nextID, deadline: due, window: .window(delay: .zero), owner: deadline.owner,
            payload: Member(deadline: deadline, generation: generation)
        )
        pools[key]?.entries.insert(member)
        rearm(key)
        return .pooled(node: key, id: nextID)
    }

    /// Arms the pool's one queue entry for its earliest deadline under its budget, keeps it when it already waits
    /// for that instant, or drops it when the pool is empty.
    private func rearm(_ key: ObjectIdentifier) {
        // Out of the dictionary while it changes, so its heap is never copied.
        guard var pool = pools.removeValue(forKey: key) else { return }
        defer { pools[key] = pool }
        let fire = pool.entries.top.map { TimerAlignment.intensiveFire(due: $0.deadline, lastWake: pool.lastWake) }
        if let armed = pool.armed, armed.fire == fire { return }
        if let armed = pool.armed { wakeups.cancel(armed.ticket) }
        pool.armed = nil
        if let fire, let top = pool.entries.top {
            let ticket = wakeups.schedule(owner: top.owner, at: fire, placement: .hidden) { [weak self] in
                self?.poolDidWake(key)
            }
            pool.armed = (ticket, fire, top.owner)
        }
    }

    /// The pool's wake: it is the node's budget wake, and every deadline of the node due by now runs in it, in due
    /// order. The queue recorded the armed owner; the others are recorded here, once each.
    private func poolDidWake(_ key: ObjectIdentifier) {
        guard let armed = pools[key]?.armed, var pool = pools.removeValue(forKey: key) else { return }
        let now = self.now
        pool.armed = nil
        pool.lastWake = now
        var due: [MainWakeUpHeap<Member>.Entry] = []
        while let entry = pool.entries.popDue(now: now) { due.append(entry) }
        pools[key] = pool
        var owners: Set<String> = [armed.owner]
        for entry in due {
            guard let deadline = entry.payload.deadline else { continue }
            if owners.insert(entry.owner).inserted { wakeups.ledger.record(entry.owner, reason: "deadline") }
            deadline.wakeDidFire(entry.payload.generation)
        }
        rearm(key)
    }

    /// Drops the pools of released nodes and empty pools whose last wake is a minute old or more: they would
    /// give the next deadline the same fire as a new pool.
    private func compactPools() {
        let now = self.now
        let minute = TimerAlignment.intensiveGrid.nanosecondCount
        pools = pools.filter { _, pool in
            guard pool.node != nil else { return false }
            guard pool.entries.count == 0, pool.armed == nil else { return true }
            guard let lastWake = pool.lastWake else { return false }
            return now < lastWake || now - lastWake < minute
        }
        compactAt = max(16, 2 * pools.count)
    }
}
