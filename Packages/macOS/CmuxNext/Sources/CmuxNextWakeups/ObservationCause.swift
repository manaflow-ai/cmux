/// Who caused a model change that an observer sees (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// sections C and D). The flush of a ``VisibleObservation`` runs in the class its cause names, as
/// Chrome gives a posted task its priority from what asked for it (`base/task/task_traits.h`:
/// `USER_BLOCKING` for the rest of a person's action, `USER_VISIBLE` for what shows on screen,
/// lower for the rest).
///
/// The order is the coalescing order, lowest first: when two causes meet, the higher one wins
/// (person > frontend > program > automation).
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

    /// The budgeted class a flush of this cause runs in; nil for ``person``, whose flush is never
    /// budgeted (the input-response pass applies it before the commit, or the next frame does).
    public var budgetedClass: BudgetedWorkClass? {
        switch self {
        case .automation: .automation
        case .program, .frontend: .visible
        case .person: nil
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

/// The app's current change cause and its person-cause epoch: the state each ``VisibleObservation``
/// reads when its tracking fires, and the queue of observations dirty since then.
///
/// The app builds one at its composition root next to its ``MainWorkScheduler`` and passes the same
/// instance to every observation and to the daemon store's drain; there is no shared instance.
///
/// Observation's `onChange` runs synchronously in the will-set of the first change, once per
/// tracking. So an observer that an automation change made dirty does not see a person change of
/// the same property later in the batch. ``personCauseEpoch`` fixes that: a person change moves
/// it, and every observation dirty since an older epoch flushes as person.
///
/// ```swift
/// // The drain, per envelope:
/// causes.withCause(.automation) { store.apply(event) }
/// // A local intent apply in the input's turn:
/// causes.withCause(.person) { model.title = newTitle }
/// ```
@MainActor
public final class ObservationCauses {
    /// The cause of the changes made now. Outside any ``withCause(_:_:)`` scope it is
    /// ``ObservationCause/program``: a change no request asked for.
    public private(set) var currentCause: ObservationCause = .program
    /// Moves once each time a person's change starts (``notePersonChange()``).
    public private(set) var personCauseEpoch: UInt64 = 0
    /// The observations dirty and not flushed yet, weakly.
    private var dirty: [ObjectIdentifier: WeakObservation] = [:]

    public init() {}

    /// Runs `body` with `cause` as the current cause, then restores the cause it had (scopes nest).
    /// A person scope moves ``personCauseEpoch`` first.
    ///
    /// - Parameters:
    ///   - cause: The cause of the changes `body` makes.
    ///   - body: The changes.
    /// - Returns: What `body` returns.
    public func withCause<T, E: Error>(_ cause: ObservationCause, _ body: () throws(E) -> T) throws(E) -> T {
        let saved = currentCause
        currentCause = cause
        defer { currentCause = saved }
        if cause == .person { notePersonChange() }
        return try body()
    }

    /// Records that a person's change starts: moves ``personCauseEpoch``, and every observation
    /// that is dirty now flushes as person. O(dirty observations).
    public func notePersonChange() {
        personCauseEpoch &+= 1
        guard !dirty.isEmpty else { return }
        for observation in live() { observation.personCauseEpochMoved() }
    }

    /// Applies, now and unbudgeted, every dirty observation whose flush class is person. The
    /// input-response pass calls it before the input turn's commit.
    ///
    /// - Returns: How many observations it applied.
    @discardableResult
    package func flushPersonCaused() -> Int {
        var flushed = 0
        for observation in live() where observation.flushIfPersonCaused() { flushed += 1 }
        return flushed
    }

    /// The observations dirty and not flushed yet (diagnostics and tests).
    package var dirtyCount: Int { dirty.values.count(where: { $0.value != nil }) }

    func register(_ observation: some CausedObservation) {
        dirty[ObjectIdentifier(observation)] = WeakObservation(value: observation)
    }

    func unregister(_ observation: some CausedObservation) {
        dirty[ObjectIdentifier(observation)] = nil
    }

    /// The live dirty observations (a copy: a flush may dirty others), dead entries dropped.
    private func live() -> [any CausedObservation] {
        var live: [any CausedObservation] = []
        live.reserveCapacity(dirty.count)
        var dead: [ObjectIdentifier] = []
        for (id, entry) in dirty {
            if let value = entry.value { live.append(value) } else { dead.append(id) }
        }
        for id in dead { dirty[id] = nil }
        return live
    }

    private struct WeakObservation {
        weak var value: (any CausedObservation)?
    }
}

/// An observation that ``ObservationCauses`` keeps while it is dirty.
@MainActor
protocol CausedObservation: AnyObject {
    /// A person's change started after this observation became dirty: its flush is person now.
    func personCauseEpochMoved()
    /// Applies now when the flush class is person; true when it applied.
    func flushIfPersonCaused() -> Bool
}
