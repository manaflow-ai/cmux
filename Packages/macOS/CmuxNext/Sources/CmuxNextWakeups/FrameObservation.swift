import CmuxNextCompat
import Observation

/// When a ``FrameObservation`` applies a change (plans/cmux-next/chrome-parity/p04-input.md,
/// section B, task 025). Every case coalesces: however many changes come before the apply, it
/// reads once and applies once.
public enum FrameObservationDelivery {
    /// Screen updates: one apply in the `visible` class at the next frame of the
    /// ``MainWorkScheduler`` (within the class budget, after a person's pending input), held while
    /// the node is hidden, occluded or frozen and run when it shows. Pass the window's node, or a
    /// narrower one; nil is node-free (it applies hidden too) and needs a `// node-free: <why>`
    /// comment at the call site.
    case visible(VisibilityNode?)
    /// Work an agent, the CLI or another process waits for: one apply in the `automation` class.
    /// It never needs a display link: with none running, it applies on the next main run loop
    /// turn, so an occluded window's automation keeps working.
    case automation
    /// A model or cache that code in the same input turn may read: one apply on the next main run
    /// loop pass, before the next event, with no frame wait. The reason says why a frame is too
    /// late (the allow comment of the old hop).
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
/// 1. `init` runs `track` under `withObservationTracking` in the caller's turn and keeps the
///    result in ``value``; it does not call `onChange`.
/// 2. The first change of anything `track` read marks the observation dirty and schedules one
///    apply for its delivery. The tracking is gone after that change, so later changes before the
///    apply cost nothing: no task, no read.
/// 3. The apply runs `track` once with a fresh tracking, stores ``value`` and calls `onChange`.
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
    /// What `track` returned last.
    public private(set) var value: Value

    private let work: MainWorkScheduler
    private let track: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private let taskOwner: MainTaskOwner
    private let counts: ObservationLedger.Owner
    private let site: MainPostSite
    /// The node's visible queue, for `.visible` with a node.
    private let nodeQueue: MainTaskQueue?
    /// Written to fire the armed tracking, so the registrar drops it.
    private let signal: VisibleObservationCancelSignal
    /// Lets the tracking callback reach this observation, weakly (it is armed before `self` exists).
    private let relay: Relay
    private var armed = false
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    /// An apply is scheduled and has not run.
    private var dirty = false
    private var cancelled = false

    /// Tracking callbacks received, stale ones included.
    package private(set) var trackingCallbacks = 0
    /// Applies scheduled (one task, post or run loop block each): one per dirty period, never one per change.
    package private(set) var deliveriesScheduled = 0

    /// Starts following `track`; reads it once, in the caller's turn, before it returns.
    ///
    /// - Parameters:
    ///   - owner: The observation's name (interned once on the scheduler's board).
    ///   - delivery: When a change applies.
    ///   - work: The app's one main-thread scheduler.
    ///   - file: The creating file (leave the default): the board names it as each apply's post site.
    ///   - line: The creating line (leave the default).
    ///   - track: The observed expression; it runs on the main actor with tracking.
    ///   - onChange: Runs after each apply's read with the new value.
    public init(owner: String, delivery: FrameObservationDelivery, on work: MainWorkScheduler,
                file: StaticString = #fileID, line: UInt = #line,
                track: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.owner = owner
        self.delivery = delivery
        self.work = work
        self.track = track
        self.onChange = onChange
        taskOwner = work.taskOwner(owner)
        counts = work.observationOwner(owner)
        site = MainPostSite(file: file, line: line)
        if case .visible(let node?) = delivery {
            nodeQueue = node.queue(.visible, owner: owner, on: work)
        } else {
            nodeQueue = nil
        }
        let signal = VisibleObservationCancelSignal(), relay = Relay()
        self.signal = signal
        self.relay = relay
        generation = 1
        value = FrameObservation.tracked(track, generation: 1, signal: signal, relay: relay, causes: work.causes)
        armed = true
        counts.armed()
        relay.observation = self
    }

    // The scheduler's queues hold no reference to this observation; only an armed tracking
    // outlives it. A generic main-actor class needs a nonisolated deinit (#23050, as
    // VisibleObservation), so the signal write hops when released off main.
    nonisolated deinit {
        guard armed else { return }
        counts.disarmed()
        let signal = self.signal
        MainDelivery().run { signal.epoch &+= 1 }
    }

    /// Stops the observation: no later read or apply. Idempotent.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        dirty = false
        disarm()
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    // MARK: Tracking

    /// Re-reads `track` with a fresh one-shot tracking whose callback marks this observation dirty.
    private func arm() {
        generation &+= 1
        armed = true
        counts.armed()
        value = Self.tracked(track, generation: generation, signal: signal, relay: relay, causes: work.causes)
    }

    /// Reads `track` under a one-shot tracking that also reads `signal` (a signal write fires it);
    /// its callback reaches the observation through `relay` on the main actor.
    private static func tracked(_ track: @escaping @MainActor () -> Value, generation: UInt64,
                                signal: VisibleObservationCancelSignal, relay: Relay,
                                causes: ObservationCauses) -> Value {
        withObservationTracking {
            _ = signal.epoch
            return track()
        } onChange: { @Sendable in
            MainDelivery().run {
                guard let observation = relay.observation else {
                    causes.noteReleasedTrackingFire()
                    return
                }
                observation.trackingFired(generation)
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
        dirty = true
        schedule()
    }

    /// Schedules the one apply of this dirty period for the delivery.
    private func schedule() {
        deliveriesScheduled += 1
        switch delivery {
        case .visible:
            if let nodeQueue {
                nodeQueue.post(key: "flush", file: site.file, line: site.line) { [weak self] in self?.apply() }
            } else {
                work.post(.visible, owner: taskOwner, file: site.file, line: site.line) { [weak self] in self?.apply() }
            }
        case .automation:
            work.post(.automation, owner: taskOwner, file: site.file, line: site.line) { [weak self] in self?.apply() }
        case .sameTurn:
            MainRunLoopBlock.perform { [weak self] in self?.apply() }
        }
    }

    /// Reads once with a fresh tracking and hands the value to `onChange`.
    private func apply() { // perf-hot: 0.05ms frame-tick (one apply per dirty observation)
        guard !cancelled, dirty else { return }
        dirty = false
        arm()
        counts.evaluated(applied: true)
        onChange(value)
    }

    /// The tracking callback's weak path to the observation.
    @MainActor private final class Relay {
        weak var observation: FrameObservation<Value>?

        // Generic by context: an isolated deinit crashes the -O build (guardrail generic-class-deinit).
        nonisolated deinit {}
    }
}
