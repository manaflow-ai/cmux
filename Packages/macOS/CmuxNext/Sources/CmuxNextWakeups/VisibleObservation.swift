import Observation

/// Follows a main-actor expression for a view, only while the view's ``VisibilityNode`` is visible
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section C). Use it only when `apply` touches
/// views; an `apply` that writes the model, the daemon, the disk or another owner uses
/// `ServiceObservation`, which also runs while nothing is on screen.
///
/// ```swift
/// // The view keeps the token; releasing it (or `cancel()`) stops the callbacks.
/// titleWatch = VisibleObservation(tabNode, owner: "TabTitle", on: mainWork, causes: causes) {
///     store.tab(id)?.title ?? ""
/// } apply: { [weak self] title in
///     self?.titleLabel.stringValue = title
/// }
/// ```
///
/// Behavior:
/// 1. `init` reads and applies the current value in the caller's turn. It arms tracking
///    (`withObservationTracking`, the same path on every macOS) only when the node is visible.
/// 2. The first change of anything `read` read marks the observation dirty with the
///    ``ObservationCauses/currentCause`` of that change (Observation's will-set, once per
///    tracking). However many changes come before the flush, the flush reads once and applies
///    once.
/// 3. The flush class is person when ``ObservationCauses/personCauseEpoch`` moved after the
///    observation became dirty, else the recorded cause: frontend or program flush in the
///    `visible` class, automation in the `automation` class, each as one budgeted task per frame
///    (Chrome's `TaskPriority`, `base/task/task_traits.h`). A person flush is never budgeted: the
///    input-response pass applies it before the commit (``ObservationCauses/flushPersonCaused()``),
///    else the next frame does, before any budgeted class.
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
    private let causes: ObservationCauses
    private let read: @MainActor () -> Value
    private let apply: @MainActor (Value) -> Void
    private let taskOwner: MainTaskOwner
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
    /// A change came and was not flushed yet.
    private var dirty = false
    /// The cause current when the observation became dirty.
    private var dirtyCause: ObservationCause = .program
    /// ``ObservationCauses/personCauseEpoch`` when the observation became dirty.
    private var dirtyEpoch: UInt64 = 0
    private var cancelled = false
    private var visibility: VisibilitySubscription?
    /// The flush clients by route, built on first use.
    private var personClient: FrameClient?
    private var visibleClient: FrameClient?
    private var automationClient: FrameClient?

    /// Tracking callbacks received, stale ones included (tests prove a hidden observation has none).
    package private(set) var trackingCallbacks = 0

    /// Starts following `read` for a view under `node`; applies its current value before it returns.
    ///
    /// - Parameters:
    ///   - node: The view's node; tracking runs only while it is visible.
    ///   - owner: The observation's name (interned once on the budget's board here).
    ///   - work: The app's one main-thread scheduler.
    ///   - causes: The app's change causes (the same instance the daemon store's drain sets).
    ///   - read: The observed expression; it runs on the main actor with tracking.
    ///   - apply: Updates the view with each new value.
    public init(_ node: VisibilityNode, owner: String, on work: MainWorkScheduler, causes: ObservationCauses,
                read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.node = node
        self.owner = owner
        self.work = work
        self.causes = causes
        self.read = read
        self.apply = apply
        isEqual = Self.equality()
        taskOwner = work.budget.board.owner(owner)
        let value = node.isVisible ? track() : read()
        if isEqual != nil { last = value }
        apply(value)
        visibility = node.subscribe(owner: owner) { [weak self] state in
            if state.isVisible { self?.show() } else { self?.hide() }
        }
    }

    // The node holds the subscription and the clients hold this observation weakly; only an armed
    // tracking outlives it. A generic main-actor class needs a nonisolated deinit (the Release
    // optimizer crashes on its isolated one, #23050), so the signal write hops when released off main.
    nonisolated deinit {
        guard armed else { return }
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
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    // MARK: Visibility

    private func show() {
        guard !cancelled, !armed, !dirty else { return }
        applyIfChanged(track())
    }

    private func hide() {
        generation &+= 1
        if armed {
            armed = false
            // Fires the tracking: the registrar drops it; the new generation makes its callback a no-op.
            signal.epoch &+= 1
        }
        if dirty {
            dirty = false
            causes.unregister(self)
        }
        personClient?.deactivate()
        visibleClient?.deactivate()
        automationClient?.deactivate()
    }

    // MARK: Tracking

    /// Reads `read` with a fresh one-shot tracking.
    private func track() -> Value {
        generation &+= 1
        armed = true
        let armedGeneration = self.generation, signal = self.signal, observed = self.read
        return withObservationTracking {
            _ = signal.epoch
            return observed()
        } onChange: { @Sendable [weak self] in
            MainDelivery().run { [weak self] in self?.trackingFired(armedGeneration) }
        }
    }

    private func trackingFired(_ generation: UInt64) { // perf-hot: 0.01ms frame-tick (each observed will-set)
        trackingCallbacks += 1
        guard !cancelled, armed, generation == self.generation else { return }
        armed = false
        dirty = true
        dirtyCause = causes.currentCause
        dirtyEpoch = causes.personCauseEpoch
        causes.register(self)
        schedule()
    }

    /// The class the flush runs in now.
    private var flushCause: ObservationCause {
        causes.personCauseEpoch != dirtyEpoch ? .person : dirtyCause
    }

    /// Activates the flush client of the current flush class, and only that one.
    private func schedule() {
        let route = Route(flushCause)
        if route != .person { personClient?.deactivate() }
        if route != .visible { visibleClient?.deactivate() }
        if route != .automation { automationClient?.deactivate() }
        client(route).activate()
    }

    /// Reads and applies, once. True while a later change made it dirty on `route` again.
    private func flush(on route: Route) -> Bool { // perf-hot: 0.05ms frame-tick (one task per dirty observer per frame)
        guard !cancelled, dirty, node.isVisible else { return false }
        dirty = false
        causes.unregister(self)
        applyIfChanged(track())
        return dirty && Route(flushCause) == route
    }

    private func applyIfChanged(_ value: Value) {
        if let isEqual, let last, isEqual(last, value) { return }
        if isEqual != nil { last = value }
        apply(value)
    }

    // MARK: Flush clients

    /// Where a flush runs: person flushes unbudgeted on the scheduler's frame clients (before every
    /// budgeted class), the others as one budgeted task of their class.
    private enum Route {
        case person
        case visible
        case automation

        init(_ cause: ObservationCause) {
            switch cause.budgetedClass {
            case nil: self = .person
            case .automation?: self = .automation
            case .visible?, .background?: self = .visible
            }
        }
    }

    private func client(_ route: Route) -> FrameClient {
        switch route {
        case .person:
            if let personClient { return personClient }
            let made = makeClient(route)
            personClient = made
            return made
        case .visible:
            if let visibleClient { return visibleClient }
            let made = makeClient(route)
            visibleClient = made
            return made
        case .automation:
            if let automationClient { return automationClient }
            let made = makeClient(route)
            automationClient = made
            return made
        }
    }

    private func makeClient(_ route: Route) -> FrameClient {
        let taskOwner = self.taskOwner
        switch route {
        case .person:
            let budget = self.work.budget
            return FrameClient(owner: self.owner, isAnimation: false, on: self.work.frames) { [weak self] _ in
                guard let self else { return false }
                return budget.run(.frame, owner: taskOwner) { self.flush(on: .person) }
            }
        case .visible, .automation:
            let budgeted: BudgetedWorkClass = route == .visible ? .visible : .automation
            let mainClass = budgeted.workClass
            return FrameClient(owner: self.owner, budgeted: budgeted, on: self.work) { [weak self] _, budget in
                guard let self else { return false }
                return budget.run(mainClass, owner: taskOwner) { self.flush(on: route) }
            }
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

extension VisibleObservation: CausedObservation {
    func personCauseEpochMoved() {
        guard dirty, !cancelled else { return }
        schedule()
    }

    func flushIfPersonCaused() -> Bool {
        guard dirty, !cancelled, node.isVisible, flushCause == .person else { return false }
        // A change the apply makes dirties the observation again and schedules its own flush.
        personClient?.deactivate()
        work.budget.run(.frame, owner: taskOwner) { _ = flush(on: .person) }
        return true
    }
}

/// Read under every ``VisibleObservation`` tracking; writing it fires (and so removes) that tracking.
@MainActor @Observable
final class VisibleObservationCancelSignal {
    var epoch: UInt64 = 0
}
