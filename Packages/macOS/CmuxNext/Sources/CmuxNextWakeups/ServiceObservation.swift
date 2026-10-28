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
/// 2. The first change of anything `read` read marks the observation dirty with the scheduler's
///    ``ObservationCauses/currentCause`` (Observation's will-set). Until the cause is person, it
///    re-arms the tracking in that turn (one read), so each later change of what it read raises
///    the cause to the highest one seen (``ObservationCause``).
/// 3. The flush evaluates `read` once and applies once, however many changes came. It is one task
///    posted on the scheduler (``MainWorkScheduler/post(_:owner:file:line:_:)``), Chrome's posted
///    task with a `TaskPriority` (`base/task/task_traits.h`): ``MainFrameBudget`` holds it while
///    input is pending or its class's budget is spent, so a burst of automation never takes the
///    person's frame. Its class is the caller's class for an automation or program cause,
///    `visible` for a frontend cause and `userBlocking` for a person cause. A person-caused flush
///    is also queued for the input-response pass, which applies it before the commit
///    (``ObservationCauses/flushPersonCaused()``); one the pass did not reach runs in its
///    `userBlocking` task. The person's own change never waits behind their next key.
/// 4. A value whose type is `Equatable` is applied only when it differs from the last value
///    applied (as `ObservationStream` emits). Wrap it in `ObservationTrigger` to apply every
///    evaluation.
/// 5. Releasing the token or calling ``cancel()`` stops every later evaluation and apply, and
///    fires the cancel signal every tracking also reads, so the registrar drops an armed tracking
///    at once (Observation has no other way to remove one).
///
/// A changed value must change on the main actor: a will-set from another thread reaches the
/// main actor one hop later (``MainDelivery``), and its cause is then the cause current at that hop.
@MainActor
public final class ServiceObservation<Value> {
    /// The class of a flush whose changes an agent, the CLI, another process or a program caused.
    public let workClass: BudgetedWorkClass
    /// The owner's name in the wakeup ledger, the watchdog's records and `debug.main_budget`.
    public let owner: String

    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    /// `==` of an Equatable value; nil applies every evaluation.
    private let isEqual: ((Value, Value) -> Bool)?
    /// The last value applied (Equatable values only).
    private var last: Value?
    /// Written to fire the armed tracking, so the registrar drops it.
    private let signal = ObservationCancelSignal()
    /// A tracking is registered and has not fired.
    private var armed = false
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    /// The highest cause of the changes since the last flush; nil while nothing is pending.
    private var dirtyCause: ObservationCause?
    /// The pass's entry for the pending person-caused flush (``ObservationCauses/enqueuePerson(_:)``).
    private var personTicket: UInt64 = 0
    private var cancelled = false
    private let work: MainWorkScheduler
    private let taskOwner: MainTaskOwner

    /// Tracking callbacks received, stale ones and the cancel signal's included (tests prove a
    /// cancelled observation's tracking is gone).
    package private(set) var trackingCallbacks = 0

    /// Starts following `read`; applies its current value before it returns.
    ///
    /// - Parameters:
    ///   - workClass: The class of a flush whose changes no person and no frontend caused:
    ///     `visible` for a model change that shows on screen through some view, `automation` for
    ///     work an agent, the CLI or another process caused, `background` for work nobody waits on.
    ///     A frontend's change flushes as `visible` and a person's as `userBlocking`, whatever this is.
    ///   - owner: The observation's name (interned once on the scheduler's board here).
    ///   - work: The app's one main-thread scheduler; its ``MainWorkScheduler/causes`` names each
    ///     change's cause.
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
        taskOwner = work.taskOwner(owner)
        let value = track()
        if isEqual != nil { last = value }
        apply(value)
    }

    // A posted flush holds this observation weakly and the pass's queue holds it weakly; only an
    // armed tracking outlives it. A generic main-actor class needs a nonisolated deinit (the
    // Release optimizer crashes on its isolated one, #23050), so the signal write hops when
    // released off main.
    nonisolated deinit {
        guard armed else { return }
        let signal = self.signal
        // main-hop-allow: the observation's own disarm from a deinit that may run off main; inline on main
        MainDelivery().run { signal.epoch &+= 1 }
    }

    /// Stops the observation: no later evaluation or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        dirtyCause = nil
        last = nil
        disarm()
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    // MARK: Tracking

    /// Evaluates `read` with a fresh one-shot tracking.
    private func track() -> Value {
        generation &+= 1
        armed = true
        let armedGeneration = generation, signal = self.signal, observed = self.read, causes = work.causes
        // view-observation-allow: this is ServiceObservation itself, the recipe R-obs target
        return withObservationTracking {
            _ = signal.epoch
            return observed()
        } onChange: { @Sendable [weak self] in
            // main-hop-allow: the observation's own onChange: inline in the change's turn on main, where it only marks it dirty for its classed flush
            MainDelivery().run { [weak self] in
                guard let self else {
                    causes.noteReleasedTrackingFire()
                    return
                }
                self.trackingFired(armedGeneration)
            }
        }
    }

    /// Fires the armed tracking, so the registrar drops it; its callback is stale.
    private func disarm() {
        generation &+= 1
        guard armed else { return }
        armed = false
        signal.epoch &+= 1
    }

    private func trackingFired(_ generation: UInt64) { // perf-hot: 0.01ms frame-tick (each observed will-set)
        trackingCallbacks += 1
        guard !cancelled, armed, generation == self.generation else { return }
        armed = false
        let cause = work.causes.currentCause
        let previous = dirtyCause
        if previous.map({ cause > $0 }) ?? true {
            dirtyCause = cause
            schedule(cause, after: previous)
        }
        // Only a higher cause can change the flush now; person is the highest.
        if dirtyCause != .person { _ = track() }
    }

    /// The class a flush of `cause` runs in: a person's in userBlocking, a frontend's in visible,
    /// the rest in the observer's own class.
    private func flushClass(_ cause: ObservationCause) -> BudgetedWorkClass {
        cause >= .frontend ? cause.budgetedClass : workClass
    }

    /// Queues the flush for `cause`, which replaced `previous`: a posted task when the class
    /// changed, and the pass's entry for a person cause.
    private func schedule(_ cause: ObservationCause, after previous: ObservationCause?) {
        if cause == .person { personTicket = work.causes.enqueuePerson(self) }
        let taskClass = flushClass(cause)
        if let previous, flushClass(previous) == taskClass { return }
        // node-free: a service's side effects must run while nothing shows (p06 rule 3).
        work.post(taskClass, owner: taskOwner) { [weak self] in self?.flushQueued(taskClass) }
    }

    /// A posted flush: flushes when the pending flush's class is still `taskClass` (a raised cause
    /// has its own task in the higher class).
    private func flushQueued(_ taskClass: BudgetedWorkClass) { // perf-hot: 0.05ms frame-tick (one task per dirty observer)
        guard !cancelled, let cause = dirtyCause, flushClass(cause) == taskClass else { return work.budget.noteRanNothing() }
        flushNow()
    }

    /// Evaluates and applies once, with a fresh tracking in place of the re-armed one.
    private func flushNow() {
        dirtyCause = nil
        disarm()
        let value = track()
        if let isEqual, let last, isEqual(last, value) { return }
        if isEqual != nil { last = value }
        apply(value)
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

extension ServiceObservation: CausedObservation {
    func isPersonPending(ticket: UInt64) -> Bool {
        !cancelled && dirtyCause == .person && ticket == personTicket
    }

    func flushPersonCaused(ticket: UInt64) -> Bool {
        guard isPersonPending(ticket: ticket) else { return false }
        // Its userBlocking task finds nothing pending and returns.
        work.budget.run(.frame, owner: taskOwner) { flushNow() }
        return true
    }
}
