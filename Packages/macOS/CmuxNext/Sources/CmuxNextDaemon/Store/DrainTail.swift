import CmuxNextWakeups

/// The drain's tail (p06-scheduler-223; plans/cmux-next/chrome-parity/p06-scheduler.md section D,
/// "Drain, ordered by cause"): the daemon transactions after the last one a person or the app's
/// frontend caused, in order.
///
/// The frame drain applies every transaction up to and including the last person or frontend one,
/// so a person's change shows in the frame after it arrives and never before the automation events
/// the daemon sent ahead of it (an ordered flush). What follows waits here and applies in budgeted
/// tasks: each task takes whole transactions from the head while they share its class (a program's
/// as visible, an agent's or the CLI's as automation), for at most a 2 ms slice and while the class
/// share is left, so an agent's storm spreads over frames within its share and never shows half a
/// transaction. A connection change or an event that asks for a snapshot never waits here: the
/// frame applies it, as the snapshot after it.
///
/// Chrome runs the input's work first and the rest by priority
/// (`base/task/sequence_manager/task_queue_selector.cc`,
/// `third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`), and
/// Mojo delivers one pipe's messages in order; the ordered flush keeps both here.
@MainActor
final class DrainTail {
    /// One daemon transaction: its events in order, with the highest cause among them.
    struct Transaction {
        let envelopes: [DaemonEventEnvelope]
        let cause: ObservationCause
        /// A person or the frontend caused it, or it changes the connection or asks for a
        /// snapshot: the frame applies it, with everything before it.
        let drainsInFrame: Bool

        init(_ envelopes: [DaemonEventEnvelope]) {
            self.envelopes = envelopes
            cause = envelopes.lazy.map(\.cause).max() ?? .program
            drainsInFrame = cause >= .frontend || envelopes.contains { $0.event.drainsInFrame }
        }

        /// The class its task runs in: visible for a program's, automation for an agent's.
        var workClass: BudgetedWorkClass { cause.budgetedClass }
    }

    /// How long one task goes on taking transactions after its first one.
    static let slice: Duration = .milliseconds(2)

    /// Runs the tail's tasks; nil: every batch applies whole in its frame and the tail stays empty.
    let scheduler: (any DrainTailScheduler)?
    private var queue: [Transaction] = []
    private var head = 0
    /// A task is posted and has not run yet.
    private var posted = false

    init(scheduler: (any DrainTailScheduler)?) {
        self.scheduler = scheduler
    }

    /// Transactions waiting (tests, diagnostics).
    var count: Int { queue.count - head }

    /// The class of the transaction at the head; nil when the tail is empty.
    var headClass: BudgetedWorkClass? { queue[checked: head]?.workClass }

    /// What the frame applies now, in order. With `flushing` (after a snapshot, or at the end of a
    /// connection), the whole tail, then all of `batch`. Otherwise, when `batch` holds a transaction a
    /// person or the frontend caused, or one that drains in the frame, the whole tail, then `batch` up
    /// to and including the last such transaction. The rest of `batch` joins the tail.
    func frame(_ batch: [DaemonEventEnvelope], flushing: Bool) -> [DaemonEventEnvelope] {
        guard scheduler != nil else { return batch }
        // The last event's transaction drains in the frame: so does the whole batch (no cut to find).
        if flushing || batch.last.map({ $0.cause >= .frontend || $0.event.drainsInFrame }) == true { return takeAll() + batch }
        let transactions = Self.transactions(in: batch)
        guard let cut = transactions.lastIndex(where: \.drainsInFrame) else {
            queue.append(contentsOf: transactions)
            return []
        }
        var now = takeAll()
        for transaction in transactions.prefix(cut + 1) { now.append(contentsOf: transaction.envelopes) }
        queue.append(contentsOf: transactions.dropFirst(cut + 1))
        return now
    }

    /// Removes and returns the transaction at the head.
    func takeHead() -> Transaction? {
        guard let transaction = queue[checked: head] else { return nil }
        head += 1
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= queue.count {
            queue.removeFirst(head)
            head = 0
        }
        return transaction
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

    /// Every event waiting, in order; the tail is empty after.
    private func takeAll() -> [DaemonEventEnvelope] {
        defer {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        return queue.dropFirst(head).flatMap(\.envelopes)
    }

    /// `batch` cut into transactions (``TransactionKey``): adjacent events with one key apply together.
    static func transactions(in batch: [DaemonEventEnvelope]) -> [Transaction] {
        var transactions: [Transaction] = []
        var current: [DaemonEventEnvelope] = []
        var key: TransactionKey?
        for envelope in batch {
            let next = TransactionKey(envelope)
            if !current.isEmpty, next == nil || next != key {
                transactions.append(Transaction(current))
                current = []
            }
            current.append(envelope)
            key = next
        }
        if !current.isEmpty { transactions.append(Transaction(current)) }
        return transactions
    }
}
