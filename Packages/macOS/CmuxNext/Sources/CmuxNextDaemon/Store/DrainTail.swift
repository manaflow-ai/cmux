import CmuxNextWakeups

/// The drain's tail (plans/cmux-next/chrome-parity/p06-scheduler.md section D,
/// "Drain, ordered by cause"): the daemon transactions after the last one a person or the app's
/// frontend caused, in order.
///
/// The frame drain applies every transaction up to and including the last person or frontend one,
/// or the last one a read-your-writes wait needs, so a person's change shows in the frame after it
/// arrives and never before the automation events the daemon sent ahead of it (an ordered flush).
/// What follows waits here and applies in budgeted tasks: each task takes whole transactions from
/// the head while they share its class (a program's as visible, an agent's or the CLI's as
/// automation), for at most a 2 ms slice and while the class share is left, so an agent's storm
/// spreads over frames within its share and never shows half a transaction. A connection change or
/// an event that asks for a snapshot never waits here: the frame applies it, as the snapshot after it.
///
/// Bounded as ``EventInbox`` is: a whole-value event (``CoalesceKey``) replaces the one of the same
/// field still waiting, and past ``limit`` events the tail collapses into one `.overflow` the frame
/// applies (one snapshot), keeping the events that outlive it.
///
/// Chrome runs the input's work first and the rest by priority
/// (`base/task/sequence_manager/task_queue_selector.cc`,
/// `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`), and
/// Mojo delivers one pipe's messages in order; the ordered flush keeps both here.
@MainActor
final class DrainTail {
    /// One daemon transaction (``TransactionRun``): its events in order, with the highest cause among them.
    struct Transaction {
        let envelopes: [DaemonEventEnvelope]
        let cause: ObservationCause
        /// A person or the frontend caused it, or it changes the connection or asks for a
        /// snapshot: the frame applies it, with everything before it.
        let drainsInFrame: Bool
        /// The field it states the whole value of, when it is one such event.
        let coalesceKey: CoalesceKey?

        init(_ envelopes: [DaemonEventEnvelope]) {
            self.envelopes = envelopes
            cause = envelopes.lazy.map(\.cause).max() ?? .program
            drainsInFrame = cause >= .frontend || envelopes.contains { $0.event.drainsInFrame }
            coalesceKey = envelopes.count == 1 ? envelopes.first.flatMap { CoalesceKey($0.event) } : nil
        }

        /// The class its task runs in: visible for a program's, automation for an agent's.
        var workClass: BudgetedWorkClass { cause.budgetedClass }

        func raisingCause(to other: ObservationCause) -> Transaction {
            Transaction(envelopes.map { $0.raisingCause(to: other) })
        }
    }

    /// How long one task goes on taking transactions after its first one.
    static let slice: Duration = .milliseconds(2)

    /// Runs the tail's tasks; nil: every batch applies whole in its frame and the tail stays empty.
    let scheduler: (any DrainTailScheduler)?
    /// The most events the tail holds before it collapses into one snapshot.
    let limit: Int
    /// Waiting transactions from `head` on; nil where a newer value of the same field replaced one.
    private var queue: [Transaction?] = []
    /// The first live slot of `queue` (`queue.count` when the tail is empty).
    private var head = 0
    /// Slots removed from the front of `queue` so far: a position in `latest` counts from the first slot ever.
    private var removed = 0
    /// The position of the waiting event per whole-value field.
    private var latest: [CoalesceKey: Int] = [:]
    /// Live transactions and their events.
    private(set) var count = 0
    private var events = 0
    /// Events a newer one of the same field replaced (tests, diagnostics).
    private(set) var coalescedCount = 0
    /// A task is posted and has not run yet.
    private var posted = false

    init(scheduler: (any DrainTailScheduler)?, limit: Int = EventInbox.defaultLimit) {
        self.scheduler = scheduler
        self.limit = max(limit, 1)
    }

    /// The class of the transaction at the head; nil when the tail is empty.
    var headClass: BudgetedWorkClass? { headTransaction?.workClass }

    private var headTransaction: Transaction? { queue[checked: head] ?? nil }

    /// What the frame applies now, in order. With `flushing` (after a snapshot, or at the end of a
    /// connection), the whole tail, then all of `batch`. Otherwise, when `batch` holds a transaction a
    /// person or the frontend caused, one that drains in the frame, or one with an event `awaited`
    /// matches (a read-your-writes wait needs it), the whole tail, then `batch` up to and including the
    /// last such transaction. The rest of `batch` joins the tail; past ``limit`` the tail collapses.
    func frame(_ batch: [DaemonEventEnvelope], flushing: Bool,
               awaited: (DaemonEventEnvelope) -> Bool = { _ in false }) -> [DaemonEventEnvelope] {
        guard scheduler != nil else { return batch }
        // The last event's transaction drains in the frame: so does the whole batch (no cut to find).
        if flushing || batch.last.map({ $0.cause >= .frontend || $0.event.drainsInFrame || awaited($0) }) == true {
            return takeAll() + batch
        }
        let transactions = Self.transactions(in: batch)
        var now: [DaemonEventEnvelope] = []
        var rest = ArraySlice(transactions)
        if let cut = transactions.lastIndex(where: { $0.drainsInFrame || $0.envelopes.contains(where: awaited) }) {
            now = takeAll()
            for transaction in transactions.prefix(cut + 1) { now.append(contentsOf: transaction.envelopes) }
            rest = transactions.dropFirst(cut + 1)
        }
        for transaction in rest { enqueue(transaction) }
        if events > limit { now += EventInbox.collapse(takeAll(), reason: "drain tail exceeded \(limit) events") }
        return now
    }

    /// Removes and returns the transaction at the head.
    func takeHead() -> Transaction? {
        guard let transaction = headTransaction else { return nil }
        if let key = transaction.coalesceKey, latest[key] == removed + head { latest[key] = nil }
        head += 1
        count -= 1
        events -= transaction.envelopes.count
        skipReplaced()
        if head == queue.count {
            removed += queue.count
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= queue.count {
            removed += head
            queue.removeFirst(head)
            head = 0
        }
        return transaction
    }

    /// Removes and returns, in order, the events of the transactions from the head through the last
    /// one with an event `awaited` matches; none when no waiting event matches.
    func take(through awaited: (DaemonEventEnvelope) -> Bool) -> [DaemonEventEnvelope] {
        let needed = queue.indices.dropFirst(head).last(where: { (queue[checked: $0] ?? nil)?.envelopes.contains(where: awaited) == true })
        guard let last = needed else { return [] }
        let through = removed + last
        var taken: [DaemonEventEnvelope] = []
        while removed + head <= through, let transaction = takeHead() { taken.append(contentsOf: transaction.envelopes) }
        return taken
    }

    /// Posts the task that applies the head, in its class, unless one is posted or the tail is empty.
    /// `run` gets the class it was posted in.
    func post(_ run: @escaping @MainActor (BudgetedWorkClass) -> Void) {
        guard !posted, let scheduler, let workClass = headClass else { return }
        posted = true
        scheduler.postDrainTail(workClass) { [weak self] in
            self?.posted = false
            run(workClass)
        }
    }

    /// Appends `transaction`; a whole-value one replaces the waiting one of the same field, with the
    /// higher cause of the two, as ``EventInbox`` does.
    private func enqueue(_ transaction: Transaction) {
        var transaction = transaction
        if let key = transaction.coalesceKey, let position = latest[key], let old = queue[checked: position - removed] ?? nil {
            queue.modify(checked: position - removed) { $0 = nil }
            count -= 1
            events -= old.envelopes.count
            coalescedCount += 1
            transaction = transaction.raisingCause(to: old.cause)
            skipReplaced()
        }
        if let key = transaction.coalesceKey { latest[key] = removed + queue.count }
        queue.append(transaction)
        count += 1
        events += transaction.envelopes.count
    }

    /// Moves `head` past the slots a newer value replaced.
    private func skipReplaced() {
        while head < queue.count, headTransaction == nil { head += 1 }
    }

    /// Every event waiting, in order; the tail is empty after.
    private func takeAll() -> [DaemonEventEnvelope] {
        defer {
            removed += queue.count
            queue.removeAll(keepingCapacity: true)
            head = 0
            latest.removeAll(keepingCapacity: true)
            count = 0
            events = 0
        }
        return queue.dropFirst(head).flatMap { $0?.envelopes ?? [] }
    }

    /// `batch` cut into transactions (``TransactionRun``): the events a run joins apply together.
    static func transactions(in batch: [DaemonEventEnvelope]) -> [Transaction] {
        var transactions: [Transaction] = []
        var current: [DaemonEventEnvelope] = []
        var run: TransactionRun?
        for envelope in batch {
            if run?.join(envelope) != true {
                if !current.isEmpty { transactions.append(Transaction(current)) }
                current = []
                run = TransactionRun(envelope)
            }
            current.append(envelope)
        }
        if !current.isEmpty { transactions.append(Transaction(current)) }
        return transactions
    }
}
