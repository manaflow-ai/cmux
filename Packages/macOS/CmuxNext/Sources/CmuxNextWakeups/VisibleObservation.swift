import Observation

/// Follows a main-actor expression for a view, only while the view's ``VisibilityNode`` is visible
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section C). Use it only when `apply` touches
/// views; an `apply` that writes the model, the daemon, the disk or another owner uses
/// `ServiceObservation`, which also runs while nothing is on screen.
///
/// ```swift
/// // The view keeps the token; releasing it (or `cancel()`) stops the callbacks.
/// titleWatch = VisibleObservation(tabNode, owner: "TabTitle", on: mainWork) {
///     store.tab(id)?.title ?? ""
/// } apply: { [weak self] title in
///     self?.titleLabel.stringValue = title
/// }
/// ```
///
/// Behavior:
/// 1. `init` reads and applies the current value in the caller's turn. It arms tracking
///    (`withObservationTracking`, the same path on every macOS) only while the node is visible.
/// 2. The first change of anything `read` read marks the observation dirty with the
///    scheduler's ``ObservationCauses/currentCause`` (Observation's will-set). Until the cause is
///    person, it re-arms the tracking in that turn (one read), so each later change of what it
///    read raises the cause to the highest one seen (``ObservationCause``). A change of something
///    it did not read never touches it.
/// 3. The flush reads once and applies once, however many changes came. It runs as one task in
///    the class of the cause (``ObservationCause/budgetedClass``) on the node's task queue
///    (``VisibilityNode/queue(_:owner:on:)``): Chrome's one task queue per priority
///    (`base/task/sequence_manager/task_queue_selector.h`), held while the node is hidden or frozen.
///    A person-caused flush is also queued for the input-response pass, which applies it before
///    the commit (``ObservationCauses/flushPersonCaused()``); one the pass did not reach runs in
///    its `visible` task.
/// 4. When the node stops being visible, a cancel signal fires the armed tracking, so the
///    registrar drops it, and a dirty flush is dropped: a hidden view reads nothing. When the node
///    shows again it reads once and applies the value.
/// 5. A value whose type is `Equatable` is applied only when it differs from the last one applied.
///
/// A change must happen on the main actor: a will-set from another thread reaches the main actor
/// one hop later (``MainDelivery``), and its cause is then the cause current at that hop.
///
/// Release the token or call ``cancel()`` when the view goes away: either fires the cancel signal,
/// so the registrar drops an armed tracking at once (Observation has no other way to remove one).
@MainActor
public final class VisibleObservation<Value> {
    /// The observation's name in the wakeup ledger, the watchdog's records and `debug.main_budget`.
    public let owner: String

    private let node: VisibilityNode
    private let work: MainWorkScheduler
    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    private let taskOwner: MainTaskOwner
    /// Its owner's counts in the scheduler's ``MainWorkScheduler/observations`` (`debug.observations`).
    private let counts: ObservationLedger.Owner
    /// `==` of an Equatable value; nil applies every read.
    private let isEqual: ((Value, Value) -> Bool)?
    /// The last value applied (Equatable values only).
    private var last: Value?
    /// Written to fire the armed tracking, so the registrar drops it.
    private let signal = VisibleObservationCancelSignal()
    /// A tracking is registered and has not fired.
    private var armed = false
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    /// The highest cause of the changes since the last flush; nil while nothing is pending.
    private var dirtyCause: ObservationCause?
    /// The pass's entry for the pending person-caused flush (``ObservationCauses/enqueuePerson(_:)``).
    private var personTicket: UInt64 = 0
    private var cancelled = false
    private var visibility: VisibilitySubscription?
    /// The node's queues the flushes run on, by class, built on first use.
    private var visibleQueue: MainTaskQueue?
    private var automationQueue: MainTaskQueue?

    /// Tracking callbacks received, stale ones included (tests prove a hidden observation has none).
    package private(set) var trackingCallbacks = 0

    /// Starts following `read` for a view under `node`; applies its current value before it returns.
    ///
    /// - Parameters:
    ///   - node: The view's node; tracking runs only while it is visible.
    ///   - owner: The observation's name (interned once on the scheduler's board).
    ///   - work: The app's one main-thread scheduler; its ``MainWorkScheduler/causes`` names each
    ///     change's cause.
    ///   - read: The observed expression; it runs on the main actor with tracking.
    ///   - apply: Updates the view with each new value.
    public init(_ node: VisibilityNode, owner: String, on work: MainWorkScheduler,
                read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.node = node
        self.owner = owner
        self.work = work
        self.read = read
        self.apply = apply
        isEqual = Self.equality()
        taskOwner = work.taskOwner(owner)
        counts = work.observations.owner(owner)
        let value = node.isVisible ? track() : read()
        if isEqual != nil { last = value }
        apply(value)
        visibility = node.subscribe(owner: owner) { [weak self] state in
            if state.isVisible { self?.show() } else { self?.hide() }
        }
    }

    // The node holds the subscription and the queues hold no reference to this observation; only
    // an armed tracking outlives it. A generic main-actor class needs a nonisolated deinit (the
    // Release optimizer crashes on its isolated one, #23050), so the signal write hops when
    // released off main.
    nonisolated deinit {
        guard armed else { return }
        counts.disarmed()
        let signal = self.signal
        MainDelivery().run { signal.epoch &+= 1 }
    }

    /// Stops the observation: no later read or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        hide()
        cancelled = true
        last = nil
        visibility?.cancel()
        visibility = nil
        visibleQueue = nil
        automationQueue = nil
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    // MARK: Visibility

    private func show() {
        guard !cancelled, !armed, dirtyCause == nil else { return }
        let start = work.budget.uptimeNanos()
        let value = track()
        counts.showReread(nanos: work.budget.uptimeNanos() &- start)
        applyIfChanged(value)
    }

    private func hide() {
        disarm()
        dirtyCause = nil
    }

    // MARK: Tracking

    /// Reads `read` with a fresh one-shot tracking.
    private func track() -> Value {
        generation &+= 1
        armed = true
        counts.armed()
        let armedGeneration = generation, signal = self.signal, observed = self.read, causes = work.causes
        return withObservationTracking {
            _ = signal.epoch
            return observed()
        } onChange: { @Sendable [weak self] in
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
        counts.disarmed()
        signal.epoch &+= 1
    }

    private func trackingFired(_ generation: UInt64) { // perf-hot: 0.01ms frame-tick (each observed will-set)
        trackingCallbacks += 1
        guard !cancelled, armed, generation == self.generation else { return }
        armed = false
        counts.disarmed()  // the tracking fired, and so is gone
        let cause = work.causes.currentCause
        let previous = dirtyCause
        if previous.map({ cause > $0 }) ?? true {
            dirtyCause = cause
            schedule(cause, after: previous)
        }
        // Only a higher cause can change the flush now; person is the highest.
        if dirtyCause != .person {
            _ = track()
            counts.evaluated()
        }
    }

    /// Queues the flush for `cause`, which replaced `previous`: a task on the class's queue when
    /// the class changed, and the pass's entry for a person cause.
    private func schedule(_ cause: ObservationCause, after previous: ObservationCause?) {
        if cause == .person { personTicket = work.causes.enqueuePerson(self) }
        let workClass = cause.budgetedClass
        if previous?.budgetedClass == workClass { return }
        queue(workClass).post(key: "flush") { [weak self] in self?.flushQueued(workClass) }
    }

    /// A queued flush task: flushes when the pending flush's class is still `workClass` (a raised
    /// cause has its own task on the higher class's queue).
    private func flushQueued(_ workClass: BudgetedWorkClass) { // perf-hot: 0.05ms frame-tick (one task per dirty observer)
        guard !cancelled, let cause = dirtyCause, cause.budgetedClass == workClass, node.isVisible else { return }
        flushNow()
    }

    /// Reads and applies once, with a fresh tracking in place of the re-armed one.
    private func flushNow() {
        dirtyCause = nil
        disarm()
        let value = track()
        counts.evaluated()
        applyIfChanged(value)
    }

    private func applyIfChanged(_ value: Value) {
        if let isEqual, let last, isEqual(last, value) { return }
        if isEqual != nil { last = value }
        counts.applied()
        apply(value)
    }

    private func queue(_ workClass: BudgetedWorkClass) -> MainTaskQueue {
        if workClass == .automation {
            if let automationQueue { return automationQueue }
            let made = node.queue(.automation, owner: owner, on: work)
            automationQueue = made
            return made
        }
        if let visibleQueue { return visibleQueue }
        let made = node.queue(.visible, owner: owner, on: work)
        visibleQueue = made
        return made
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

extension VisibleObservation: CausedObservation {
    func isPersonPending(ticket: UInt64) -> Bool {
        !cancelled && dirtyCause == .person && ticket == personTicket
    }

    func flushPersonCaused(ticket: UInt64) -> Bool {
        guard isPersonPending(ticket: ticket), node.isVisible, !node.isFrozen else { return false }
        // Its visible task finds nothing pending and returns.
        work.budget.run(.frame, owner: taskOwner) { flushNow() }
        return true
    }
}

/// Read under every ``VisibleObservation`` tracking; writing it fires (and so removes) that tracking.
@MainActor @Observable
final class VisibleObservationCancelSignal {
    var epoch: UInt64 = 0
}
