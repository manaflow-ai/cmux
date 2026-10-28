import Observation

/// Follows a main-actor expression for a view, only while the view's ``VisibilityNode`` renders (it is
/// visible, or a capture vote holds it: ``VisibilityNode/wantsFrames``)
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
///    (`withObservationTracking`, the same path on every macOS) only while the node renders.
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
///    its `userBlocking` task.
/// 4. When the node stops rendering (it is hidden and no capture vote holds it), a cancel signal
///    fires the armed tracking, so the registrar drops it, and a dirty flush is dropped: a hidden
///    view reads nothing. When the node renders again it reads once and applies the value, by the
///    node's show order (``VisibilityNode/resolvedShowOrder``, task 213): in the show turn, or as
///    one userBlocking task posted after the show pass in rank order. A `firstFrame` observation
///    reads in the show turn whatever the order. The ledger records each show re-read and its time.
/// 5. While a warm vote holds the hidden node (``VisibilityNode/warmVote(reason:)``), it reads in
///    idle time with tracking and keeps the value without applying it; a change makes it read again
///    in idle time. A show while that value is still current applies it with no read.
/// 6. A value whose type is `Equatable` is applied only when it differs from the last one applied.
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
    private let apply: @MainActor (Value) -> Void
    private let taskOwner: MainTaskOwner
    /// Reads in the show turn whatever the node's show order (its view must be right in the first frame).
    private let firstFrame: Bool
    /// The tracking, its cancel signal and the pending change's cause (shared with ``FrameObservation``).
    private let tracker: ObservationTracker<Value>
    /// `==` of an Equatable value; nil applies every read.
    private let isEqual: ((Value, Value) -> Bool)?
    /// The last value applied (Equatable values only).
    private var last: Value?
    private var cancelled = false
    private var visibility: VisibilitySubscription?
    private var warmth: VisibilitySubscription?
    /// A show waits for its userBlocking task (``VisibilityNode/ShowOrder/afterShow(rank:)``).
    private var showPending = false
    /// The value a warm idle read got while the node was hidden; current while the tracking it armed is clean.
    private var warmValue: Value?
    private var warmReadPosted = false
    /// The node's queues the flushes run on, by class, built on first use.
    private var queues: [BudgetedWorkClass: MainTaskQueue] = [:]

    /// Tracking callbacks received, stale ones included (tests prove a hidden observation has none).
    package var trackingCallbacks: Int { tracker.callbacks }

    /// Starts following `read` for a view under `node`; applies its current value before it returns.
    ///
    /// - Parameters:
    ///   - node: The view's node; tracking runs only while it is visible.
    ///   - owner: The observation's name (interned once on the scheduler's board).
    ///   - work: The app's one main-thread scheduler; its ``MainWorkScheduler/causes`` names each
    ///     change's cause.
    ///   - firstFrame: Read in the show turn whatever the node's show order: the view must be right in
    ///     the first frame after a show.
    ///   - read: The observed expression; it runs on the main actor with tracking.
    ///   - apply: Updates the view with each new value.
    public init(_ node: VisibilityNode, owner: String, on work: MainWorkScheduler, firstFrame: Bool = false,
                read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
        self.node = node
        self.owner = owner
        self.work = work
        self.firstFrame = firstFrame
        self.apply = apply
        isEqual = ObservationTracker<Value>.equality()
        taskOwner = work.taskOwner(owner)
        tracker = ObservationTracker(counts: work.observationOwner(owner), causes: work.causes, read: read)
        tracker.client = self
        let value = node.wantsFrames ? tracker.track() : tracker.readUntracked()
        if isEqual != nil { last = value }
        apply(value)
        visibility = node.subscribeRendering(owner: owner) { [weak self] rendering in
            if rendering { self?.show() } else { self?.hide() }
        }
        warmth = node.subscribeWarm(owner: owner) { [weak self] warm in self?.warmChanged(warm) }
        if node.isWarm, !node.wantsFrames { postWarmRead() }
    }

    // The node holds the subscription and the queues hold no reference to this observation; the
    // tracker's deinit drops an armed tracking. Generic: an isolated deinit crashes the -O build
    // (#23050, guardrail generic-class-deinit).
    nonisolated deinit {}

    /// Stops the observation: no later read or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        hide()
        last = nil
        visibility?.cancel()
        visibility = nil
        warmth?.cancel()
        warmth = nil
        queues.removeAll()
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    // MARK: Visibility

    private func show() {
        guard !cancelled else { return }
        guard !firstFrame, case .afterShow(let rank) = node.resolvedShowOrder else { return showNow() }
        showPending = true
        node.postAfterShow(rank: rank) { [weak self] in self?.postQueuedShow() }
    }

    private func postQueuedShow() {
        guard !cancelled, showPending else { return }
        queue(.userBlocking).post(key: "show") { [weak self] in self?.showQueued() }
    }

    private func showQueued() {
        guard !cancelled, showPending, node.wantsFrames else { return work.budget.noteRanNothing() }
        showNow()
    }

    /// Applies the current value: the warm one when nothing changed since its read, else one re-read.
    private func showNow() {
        showPending = false
        let warm = warmValue
        warmValue = nil
        if tracker.isArmed, tracker.dirtyCause == nil, let warm { return applyIfChanged(warm) }
        tracker.clean()
        tracker.disarm()
        let start = work.budget.uptimeNanos()
        let value = tracker.track()
        tracker.counts.showReread(nanos: work.budget.uptimeNanos() &- start)
        applyIfChanged(value)
    }

    private func hide() {
        // A held show task would run ahead of the next show's rank order: drop it with its queue.
        if showPending { queues[.userBlocking] = nil }
        showPending = false
        warmValue = nil
        tracker.disarm()
        tracker.clean()
        if !cancelled, node.isWarm { postWarmRead() }
    }

    // MARK: Warm

    private func warmChanged(_ warm: Bool) {
        guard !cancelled, !node.wantsFrames else { return }
        if warm { return postWarmRead() }
        warmValue = nil
        tracker.disarm()
        tracker.clean()
    }

    private func postWarmRead() {
        guard !warmReadPosted else { return }
        warmReadPosted = true
        work.postIdle(owner: taskOwner) { [weak self] _ in self?.warmRead() }
    }

    /// Reads with tracking and keeps the value for the show, unless the kept one is still current.
    private func warmRead() {
        warmReadPosted = false
        guard !cancelled, node.isWarm, !node.wantsFrames else { return }
        if tracker.isArmed, tracker.dirtyCause == nil, warmValue != nil { return }
        tracker.clean()
        tracker.disarm()
        warmValue = tracker.track()
        tracker.counts.evaluated()
    }

    // MARK: Flush

    /// A queued flush task: flushes when the pending flush's class is still `workClass` (a raised
    /// cause has its own task on the higher class's queue).
    private func flushQueued(_ workClass: BudgetedWorkClass) { // perf-hot: 0.05ms frame-tick (one task per dirty observer)
        guard !cancelled, let cause = tracker.dirtyCause, cause.budgetedClass == workClass, node.wantsFrames else {
            return work.budget.noteRanNothing()
        }
        flushNow()
    }

    /// Reads and applies once, with a fresh tracking in place of the re-armed one.
    private func flushNow() {
        showPending = false
        tracker.clean()
        tracker.disarm()
        let value = tracker.track()
        tracker.counts.evaluated()
        applyIfChanged(value)
    }

    private func applyIfChanged(_ value: Value) {
        if let isEqual, let last, isEqual(last, value) { return }
        if isEqual != nil { last = value }
        tracker.counts.applied()
        apply(value)
    }

    private func queue(_ workClass: BudgetedWorkClass) -> MainTaskQueue {
        if let queue = queues[workClass] { return queue }
        let made = node.queue(workClass, owner: owner, on: work)
        queues[workClass] = made
        return made
    }
}

extension VisibleObservation: ObservationTrackerClient {
    /// Queues the flush for `cause`: a task on the class's queue when the class changed (the
    /// tracker queued a person cause for the pass). While the node is hidden, a warm read in idle time.
    func dirtied(_ cause: ObservationCause, after previous: ObservationCause?) {
        // Only a warm read arms a tracking while the node is hidden: its value is stale now.
        guard node.wantsFrames else {
            warmValue = nil
            return postWarmRead()
        }
        let workClass = cause.budgetedClass
        if previous?.budgetedClass == workClass { return }
        queue(workClass).post(key: "flush") { [weak self] in self?.flushQueued(workClass) }
    }

    func flushPersonCaused() -> Bool {
        guard !cancelled, node.wantsFrames, !node.isFrozen else { return false }
        // Its userBlocking task finds nothing pending and returns.
        work.budget.run(.frame, owner: taskOwner) { flushNow() }
        return true
    }
}
