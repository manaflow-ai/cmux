import CmuxNextCompat

/// When a ``FrameObservation`` applies a change (plans/cmux-next/chrome-parity/p04-input.md,
/// section B, task 025). Every case coalesces: however many changes come before the apply, it
/// reads once and applies once. Whatever the delivery, a change a person's input caused
/// (``ObservationCauses/currentCause`` is ``ObservationCause/person``) applies in that input's
/// response pass, before its commit (``ObservationCauses/flushPersonCaused()``).
public enum FrameObservationDelivery {
    /// Screen updates: one apply in the `visible` class at the next frame of the
    /// ``MainWorkScheduler`` (within the class budget, after a person's pending input). Pass the
    /// window's node, or a narrower one: while it does not render (hidden, and no capture vote holds
    /// it: ``VisibilityNode/wantsFrames``) the observation tracks nothing, and when it renders again
    /// it reads once and applies a changed value. nil is node-free (it applies
    /// hidden too) and needs a `// node-free: <why>` comment at the call site.
    case visible(VisibilityNode?)
    /// Work an agent, the CLI or another process waits for: one apply in the `automation` class.
    /// It never needs a display link: with none running, it applies on the next main run loop
    /// turn, so an occluded window's automation keeps working.
    case automation
    /// A model or cache that code in the change's own turn reads. That reader calls
    /// ``FrameObservation/flushIfDirty()`` (or reads ``FrameObservation/currentValue``) first,
    /// which applies a pending change at once, as Blink forces a style and layout update on read
    /// (`Document::UpdateStyleAndLayoutForNode`, third_party/blink/renderer/core/dom/document.cc).
    /// With no such read, it applies on the next main run loop pass, with no frame wait. The
    /// reason says why a frame is too late (the allow comment of the old hop).
    case sameTurn(StaticString)
}

/// Follows a main-actor expression and applies its new value once per delivery
/// (``FrameObservationDelivery``), not once per change: the replacement for a
/// `withObservationTracking { } onChange: { Task { @MainActor in ... } }` hop, which made one
/// task per change and re-read on each.
///
/// Blink coalesces the same way: a DOM change only marks the frame for a visual update
/// (`PageAnimator::ScheduleVisualUpdate`, third_party/blink/renderer/core/page/page_animator.cc),
/// and the lifecycle runs once in the next BeginMainFrame however many changes came.
///
/// ```swift
/// // The owner keeps the token; releasing it (or `cancel()`) stops the callbacks.
/// badgeWatch = FrameObservation(owner: "UnreadBadge", delivery: .visible(windowNode), on: mainWork) {
///     store.unreadCount
/// } onChange: { [weak self] count in
///     self?.badge.count = count
/// }
/// ```
///
/// Behavior:
/// 1. `init` reads `track` in the caller's turn (tracking it unless its node does not render) and keeps
///    the result in ``value``; it does not call `onChange`.
/// 2. The first change of anything `track` read marks the observation dirty with the scheduler's
///    ``ObservationCauses/currentCause`` and schedules one apply for its delivery; a person cause
///    also queues it for the input-response pass. Until the cause is person, each change re-arms
///    the tracking (one read, no task), so a person's later change still raises it; after that,
///    changes cost nothing until the apply. The tracking core is ``VisibleObservation``'s.
/// 3. The apply reads `track` once with a fresh tracking and stores ``value``; when the value is
///    `Equatable` and equal to the one before, it does not call `onChange`.
///
/// A change off the main thread reaches the main actor one hop later (``MainDelivery``).
/// Release the token or call ``cancel()`` when the owner goes away: either fires the cancel
/// signal, so the registrar drops an armed tracking at once.
@MainActor
public final class FrameObservation<Value> {
    /// The observation's name on the board, in the watchdog's records and `debug.observations`.
    public let owner: String
    /// When it applies.
    public let delivery: FrameObservationDelivery
    /// What `track` returned at the last apply (or at `init`). ``currentValue`` applies a pending
    /// change first.
    public private(set) var value: Value

    private let work: MainWorkScheduler
    private let onChange: @MainActor (Value) -> Void
    private let taskOwner: MainTaskOwner
    private let site: MainPostSite
    /// The `.visible` delivery's node; nil for the other deliveries and a node-free `.visible`.
    private let node: VisibilityNode?
    /// The node's visible queue the applies run on.
    private let nodeQueue: MainTaskQueue?
    /// The tracking, its cancel signal and the pending change's cause (shared with ``VisibleObservation``).
    private let tracker: ObservationTracker<Value>
    /// `==` of an Equatable value; nil calls `onChange` on every apply.
    private let isEqual: ((Value, Value) -> Bool)?
    private var visibility: VisibilitySubscription?
    private var cancelled = false

    /// Tracking callbacks received, stale ones included.
    package var trackingCallbacks: Int { tracker.callbacks }
    /// Applies scheduled (one task, post or run loop block each): one per dirty period, never one per change.
    package private(set) var deliveriesScheduled = 0

    /// Starts following `track`; reads it once, in the caller's turn, before it returns.
    ///
    /// - Parameters:
    ///   - owner: The observation's name (interned once on the scheduler's board).
    ///   - delivery: When a change applies.
    ///   - work: The app's one main-thread scheduler; its ``MainWorkScheduler/causes`` names each
    ///     change's cause.
    ///   - file: The creating file (leave the default): the board names it as each apply's post site.
    ///   - line: The creating line (leave the default).
    ///   - track: The observed expression; it runs on the main actor with tracking.
    ///   - onChange: Runs after an apply's read with a new value.
    public init(owner: String, delivery: FrameObservationDelivery, on work: MainWorkScheduler,
                file: StaticString = #fileID, line: UInt = #line,
                track: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.owner = owner
        self.delivery = delivery
        self.work = work
        self.onChange = onChange
        taskOwner = work.taskOwner(owner)
        site = MainPostSite(file: file, line: line)
        var visibleNode: VisibilityNode?
        if case .visible(let given?) = delivery { visibleNode = given }
        node = visibleNode
        nodeQueue = visibleNode?.queue(.visible, owner: owner, on: work)
        isEqual = ObservationTracker<Value>.equality()
        let tracker = ObservationTracker(counts: work.observationOwner(owner), causes: work.causes, read: track)
        self.tracker = tracker
        let tracks = visibleNode?.wantsFrames ?? true
        value = tracks ? tracker.track() : tracker.readUntracked()
        tracker.client = self
        visibility = visibleNode?.subscribeRendering(owner: owner) { [weak self] rendering in
            if rendering { self?.show() } else { self?.hide() }
        }
    }

    // The scheduler's queues hold no reference to this observation; the tracker's deinit drops an
    // armed tracking. Generic: an isolated deinit crashes the -O build (#23050, guardrail
    // generic-class-deinit).
    nonisolated deinit {}

    /// Stops the observation: no later read or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        tracker.disarm()
        tracker.clean()
        visibility?.cancel()
        visibility = nil
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    /// Applies a pending change now, in the caller's turn, so a reader in the change's own turn
    /// sees it (in ``value`` and in what `onChange` writes); the scheduled apply then finds
    /// nothing. A `.visible` observation whose node is hidden or frozen applies nothing.
    public func flushIfDirty() {
        guard tracker.dirtyCause != nil, mayApplyNow else { return }
        applyNow()
    }

    /// ``value`` after ``flushIfDirty()``: the newest value in the change's own turn.
    public var currentValue: Value {
        flushIfDirty()
        return value
    }

    private var mayApplyNow: Bool {
        guard !cancelled else { return false }
        guard let node else { return true }
        return node.wantsFrames && !node.isFrozen
    }

    // MARK: Visibility

    private func show() {
        guard !cancelled, !tracker.isArmed, tracker.dirtyCause == nil else { return }
        let start = work.budget.uptimeNanos()
        let previous = value
        value = tracker.track()
        tracker.counts.showReread(nanos: work.budget.uptimeNanos() &- start)
        guard isNew(since: previous) else { return }
        tracker.counts.applied()
        onChange(value)
    }

    private func hide() {
        tracker.disarm()
        tracker.clean()
    }

    // MARK: Apply

    /// Schedules the one apply of this dirty period for the delivery.
    private func schedule() {
        deliveriesScheduled += 1
        switch delivery {
        case .visible:
            if let nodeQueue {
                nodeQueue.post(key: "flush", file: site.file, line: site.line) { [weak self] in self?.applyQueued() }
            } else {
                work.post(.visible, owner: taskOwner, file: site.file, line: site.line) { [weak self] in self?.applyQueued() }
            }
        case .automation:
            work.post(.automation, owner: taskOwner, file: site.file, line: site.line) { [weak self] in self?.applyQueued() }
        case .sameTurn:
            MainRunLoopBlock.perform { [weak self] in self?.applyQueued() }
        }
    }

    /// The scheduled apply: it finds nothing when the input-response pass, a ``flushIfDirty()``
    /// or a hide ended the dirty period first.
    private func applyQueued() { // perf-hot: 0.05ms frame-tick (one apply per dirty observation)
        guard !cancelled, tracker.dirtyCause != nil else { return }
        applyNow()
    }

    /// Reads once with a fresh tracking in place of the re-armed one, and hands a new value to `onChange`.
    private func applyNow() {
        tracker.clean()
        tracker.disarm()
        let previous = value
        value = tracker.track()
        let changed = isNew(since: previous)
        tracker.counts.evaluated(applied: changed)
        if changed { onChange(value) }
    }

    /// Whether ``value`` differs from `previous`; always true for a value that is not `Equatable`.
    private func isNew(since previous: Value) -> Bool {
        guard let isEqual else { return true }
        return !isEqual(previous, value)
    }
}

extension FrameObservation: ObservationTrackerClient {
    /// Schedules the apply when a dirty period starts; a raised cause needs nothing more (the
    /// tracker queued a person cause for the pass).
    func dirtied(_ cause: ObservationCause, after previous: ObservationCause?) {
        if previous == nil { schedule() }
    }

    func flushPersonCaused() -> Bool {
        guard mayApplyNow else { return false }
        // Its scheduled apply finds nothing pending and returns.
        work.budget.run(.frame, owner: taskOwner) { applyNow() }
        return true
    }
}
