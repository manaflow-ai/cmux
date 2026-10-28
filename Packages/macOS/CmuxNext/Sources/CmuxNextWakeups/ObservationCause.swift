/// Who caused a model change that an observer sees (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// sections C and D). The flush of a ``VisibleObservation`` runs in the class its cause names, as
/// Chrome gives a posted task its priority from what asked for it (`base/task/task_traits.h`:
/// `USER_BLOCKING` for the rest of a person's action, `USER_VISIBLE` for what shows on screen,
/// lower for the rest).
///
/// The order is the coalescing order, lowest first. While an observer is dirty, each change of
/// what it read raises its cause to the higher one (person > frontend > program > automation), and
/// its flush runs in the class of that highest cause.
///
/// The cause is for scheduling only. Authorization code never reads it.
public enum ObservationCause: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// An agent, the CLI, MCP, a socket or page automation asked for the change.
    case automation
    /// A program changed it with no request in scope: PTY output, an OSC title, a hook, a reap.
    case program
    /// The app's own frontend asked for it (a request with the app's origin).
    case frontend
    /// A person's input in this app caused it (an echo of their mutation, a local intent apply).
    case person

    public static func < (lhs: ObservationCause, rhs: ObservationCause) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The budgeted class a flush of this cause runs in when the input-response pass does not
    /// apply it first (``ObservationCauses/flushPersonCaused()``). A person flush that missed the
    /// pass is the rest of the person's action: ``BudgetedWorkClass/userBlocking``, ahead of visible
    /// work, capped at the visible + automation shares, never ahead of the person's own pending
    /// input.
    public var budgetedClass: BudgetedWorkClass {
        switch self {
        case .automation: .automation
        case .program, .frontend: .visible
        case .person: .userBlocking
        }
    }

    public var description: String {
        switch self {
        case .automation: "automation"
        case .program: "program"
        case .frontend: "frontend"
        case .person: "person"
        }
    }
}

/// The cause of the changes made now, and the person-caused observations the input-response pass
/// applies before the commit. The ``MainWorkScheduler`` builds it (``MainWorkScheduler/causes``),
/// so every observation, the daemon store's drain and the pass share one instance with the
/// scheduler they already get.
///
/// ```swift
/// // The daemon store's drain, per envelope (`DaemonStore.applyBatch`):
/// mainWork.causes.withCause(envelope.cause) { store.apply(envelope.event) }
/// // An action run, by who started it (`ActionRegistry.runScoped`): a person's run is person,
/// // the CLI's, MCP's or a script's automation; its local intents apply in that scope.
/// mainWork.causes.withCause(invocation.origin.observationCause) { handler(invocation) }
/// ```
@MainActor
public final class ObservationCauses {
    /// The cause of the changes made now. Outside any ``withCause(_:_:)`` scope it is
    /// ``ObservationCause/program``: a change no request asked for.
    public private(set) var currentCause: ObservationCause = .program
    /// Trackings that fired after their observation was released. A released token's deinit fires
    /// its armed tracking once, so the registrar drops it; a count that grows with later changes
    /// is a tracking a token leaked (p06-scheduler.md risk 13).
    package private(set) var releasedTrackingFires = 0

    private let budget: MainFrameBudget
    /// The observations whose flush became person-caused, in that order, weakly. An entry is
    /// stale once its observation flushed by another route or became person-caused again (a new
    /// ticket); stale entries are skipped and compacted away.
    private var personQueue: [PersonEntry] = []
    private var head = 0
    private var nextTicket: UInt64 = 0
    /// The queue length at which ``enqueuePerson(_:)`` drops stale entries, doubled from the live
    /// count after each pass, so dropping costs O(1) amortized per entry.
    private var compactAt = 64

    init(budget: MainFrameBudget) {
        self.budget = budget
    }

    /// Runs `body` with `cause` as the current cause, then restores the cause it had (scopes nest).
    ///
    /// - Parameters:
    ///   - cause: The cause of the changes `body` makes.
    ///   - body: The changes.
    /// - Returns: What `body` returns.
    public func withCause<T, E: Error>(_ cause: ObservationCause, _ body: () throws(E) -> T) throws(E) -> T {
        let saved = currentCause
        currentCause = cause
        defer { currentCause = saved }
        return try body()
    }

    /// Applies the person-caused observations, oldest first, unbudgeted, until they took the
    /// userBlocking cap (the visible + automation shares, p06-scheduler.md "userBlocking"); the
    /// first always applies. The input-response pass calls it before the input turn's commit.
    /// What it leaves applies in its `userBlocking` flush, in a later frame.
    ///
    /// - Returns: How many observations it applied.
    @discardableResult
    package func flushPersonCaused() -> Int { // perf-hot: 3.5ms action-budget (in the input's turn, capped at the visible + automation shares)
        let cap = MainFrameBudget.nanos(budget.budgets.visible + budget.budgets.automation)
        let start = budget.uptimeNanos()
        var flushed = 0
        while head < personQueue.count {
            if flushed > 0, budget.uptimeNanos() &- start >= cap { break }
            let entry = personQueue[head]
            personQueue[head] = PersonEntry()
            head += 1
            if let observation = entry.value, observation.flushPersonCaused(ticket: entry.ticket) { flushed += 1 }
        }
        if head == personQueue.count {
            personQueue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= personQueue.count {
            personQueue.removeFirst(head)
            head = 0
        }
        return flushed
    }

    /// The person-caused observations not applied yet (diagnostics and tests). O(queue).
    package var personPendingCount: Int {
        personQueue[head...].count(where: { $0.value?.isPersonPending(ticket: $0.ticket) ?? false })
    }

    /// Queues `observation` for the pass; returns its ticket, which names this entry.
    func enqueuePerson(_ observation: some CausedObservation) -> UInt64 {
        nextTicket &+= 1
        if personQueue.count - head >= compactAt { compact() }
        personQueue.append(PersonEntry(value: observation, ticket: nextTicket))
        return nextTicket
    }

    func noteReleasedTrackingFire() {
        releasedTrackingFires += 1
    }

    private func compact() {
        personQueue = personQueue[head...].filter { $0.value?.isPersonPending(ticket: $0.ticket) ?? false }
        head = 0
        compactAt = max(64, personQueue.count * 2)
    }

    private struct PersonEntry {
        weak var value: (any CausedObservation)?
        var ticket: UInt64 = 0
    }
}

/// An observation that ``ObservationCauses`` queues for the input-response pass.
@MainActor
protocol CausedObservation: AnyObject {
    /// Whether the entry `ticket` still names a person-caused flush that has not run.
    func isPersonPending(ticket: UInt64) -> Bool
    /// Applies now when ``isPersonPending(ticket:)`` and its node may run; true when it applied.
    func flushPersonCaused(ticket: UInt64) -> Bool
}
