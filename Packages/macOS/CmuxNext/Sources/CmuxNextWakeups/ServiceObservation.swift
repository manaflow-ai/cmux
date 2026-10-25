import Observation

/// Follows a main-actor expression for an owner that is not a view: a service, a store, a
/// coordinator whose `apply` writes the model, the daemon, the disk or another owner
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section C, rule 3). An `apply` that only
/// touches views uses `VisibleObservation`, which stops while its node is hidden; a service's
/// side effects must still happen while nothing is on screen, so this type has no node.
///
/// ```swift
/// // The owner keeps the token; releasing it (or `cancel()`) stops the callbacks.
/// tabWatch = ServiceObservation(.automation, owner: "TabWatcher", on: mainWork) {
///     store.tabIDs
/// } apply: { [weak self] ids in
///     self?.reconcile(ids)
/// }
/// ```
///
/// Behavior, the same tracking and coalescing as `VisibleObservation`:
/// 1. `init` evaluates `read` inside `withObservationTracking` and applies that value in the
///    caller's turn.
/// 2. A change of anything `read` read marks the observation dirty (Observation's will-set, once
///    per tracking) and activates its budgeted ``FrameClient``. However many changes come before
///    the next frame, the frame runs ONE task in the observation's class: it evaluates `read` again
///    with fresh tracking and applies the value. The class is the task's priority, as Chrome's
///    `TaskPriority` is a posted task's (`base/task/task_traits.h`): ``MainFrameBudget`` holds it
///    while input is pending or the class's budget is spent, so a burst of automation never takes
///    the person's frame.
/// 3. A value whose type is `Equatable` is applied only when it differs from the last value
///    applied (as `ObservationStream` emits). Wrap it in `ObservationTrigger` to apply every
///    evaluation.
/// 4. Releasing the token or calling ``cancel()`` stops every later evaluation and apply. A
///    tracking armed at that moment stays registered until the next change of a value it read,
///    which then does nothing (Observation has no way to remove one).
///
/// A changed value must change on the main actor: a will-set from another thread reaches the
/// main actor one hop later (``MainDelivery``), and the frame then reads the stored value.
@MainActor
public final class ServiceObservation<Value> {
    /// The class every flush runs in.
    public let workClass: BudgetedWorkClass
    /// The owner's name in the wakeup ledger, the watchdog's records and `debug.main_budget`.
    public let owner: String

    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    /// `==` of an Equatable value; nil applies every evaluation.
    private let isEqual: ((Value, Value) -> Bool)?
    /// The last value applied (Equatable values only).
    private var last: Value?
    /// A change came since the last evaluation.
    private var dirty = false
    private var cancelled = false
    /// Built in init (lazy because its callback captures self).
    private lazy var client: FrameClient = makeClient()
    private let work: MainWorkScheduler
    private let taskOwner: MainTaskOwner

    /// Starts following `read`; applies its current value before it returns.
    ///
    /// - Parameters:
    ///   - workClass: The class of every later flush: `visible` for a model change that shows on
    ///     screen through some view, `automation` for work an agent, the CLI or another process
    ///     caused, `background` for work nobody waits on.
    ///   - owner: The observation's name (interned once on the budget's board here).
    ///   - work: The app's one main-thread scheduler.
    ///   - read: The observed expression; it runs on the main actor with tracking.
    ///   - apply: The side effect for each new value.
    public init(_ workClass: BudgetedWorkClass, owner: String, on work: MainWorkScheduler,
                read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.workClass = workClass
        self.owner = owner
        self.work = work
        self.read = read
        self.apply = apply
        isEqual = Self.equality()
        taskOwner = work.budget.board.owner(owner)
        let value = track()
        if isEqual != nil { last = value }
        apply(value)
    }

    /// Stops the observation: no later evaluation or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        dirty = false
        last = nil
        client.deactivate()
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    /// Evaluates `read` with a fresh one-shot tracking.
    private func track() -> Value {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            MainDelivery().run { [weak self] in self?.trackedValueWillChange() }
        }
    }

    private func trackedValueWillChange() {
        guard !cancelled else { return }
        dirty = true
        client.activate()
    }

    /// The frame's one task: re-reads and applies. True while a change came during it.
    private func flush() -> Bool {
        guard !cancelled, dirty else { return false }
        dirty = false
        let value = track()
        if let isEqual, let last, isEqual(last, value) { return dirty }
        if isEqual != nil { last = value }
        apply(value)
        return dirty && !cancelled
    }

    private func makeClient() -> FrameClient {
        let workClass = workClass.workClass, taskOwner = taskOwner
        return FrameClient(owner: owner, budgeted: self.workClass, on: work) { [weak self] _, budget in
            guard let self else { return false }
            return budget.run(workClass, owner: taskOwner) { self.flush() }
        }
    }

    /// `==` for an `Equatable` value, nil for any other (no dedupe).
    private static func equality() -> ((Value, Value) -> Bool)? {
        guard let type = Value.self as? any Equatable.Type else { return nil }
        return equality(type)
    }

    private static func equality<E: Equatable>(_: E.Type) -> (Value, Value) -> Bool {
        { lhs, rhs in (lhs as? E) == (rhs as? E) }
    }
}
