import Observation

/// Runs a main-actor `render` now, and again once per delivery (``FrameObservationDelivery``)
/// after anything it read changes: the replacement for a render loop that re-armed its tracking in
/// a main-actor task per change, with no class, no owner and no visibility.
///
/// The render's reads are tracked once per render. Their first change bumps a generation that a
/// ``FrameObservation`` follows, so the observation's rules decide when the render runs again:
/// one run in the delivery's class on the scheduler (after the person's pending input), nothing
/// while a `.visible` node is hidden (one run when it shows), and the input-response pass for a
/// change the person caused (before that input's commit). Blink coalesces the same way: a change
/// only schedules a visual update (`PageAnimator::ScheduleVisualUpdate`,
/// third_party/blink/renderer/core/page/page_animator.cc), and the lifecycle runs once.
///
/// Use it where the render reads too many values to name as one; where the inputs are one value,
/// follow that value with a ``FrameObservation`` and apply it. The render's tracking is spent at
/// its first change, so a person's change after a program change in the same dirty period renders
/// at the delivery's apply, not in the input-response pass.
///
/// ```swift
/// // The owner keeps the token; releasing it (or `cancel()`) stops the renders.
/// chromeLoop = ObservationLoop(owner: "browser.chrome", delivery: .visible(tabNode), on: mainWork) { [weak self] in
///     self?.render()
/// }
/// ```
@MainActor
public final class ObservationLoop {
    /// The loop's name on the board, in the watchdog's records and `debug.observations`.
    public let owner: String

    private let render: @MainActor () -> Void
    private let trigger = ObservationLoopTrigger()
    private var watch: FrameObservation<UInt64>?
    private var cancelled = false

    /// Renders run, the one in `init` included.
    package private(set) var renders = 0
    /// Re-renders scheduled: one per dirty period, never one per change.
    package var deliveriesScheduled: Int { watch?.deliveriesScheduled ?? 0 }

    /// Renders once, in the caller's turn, and follows what the render read.
    ///
    /// - Parameters:
    ///   - owner: The loop's name (interned once on the scheduler's board).
    ///   - delivery: When a change renders again.
    ///   - work: The app's one main-thread scheduler.
    ///   - file: The creating file (leave the default): the board names it as each render's post site.
    ///   - line: The creating line (leave the default).
    ///   - render: Reads the model and updates its owner; it runs on the main actor with tracking.
    public init(owner: String, delivery: FrameObservationDelivery, on work: MainWorkScheduler,
                file: StaticString = #fileID, line: UInt = #line, _ render: @escaping @MainActor () -> Void) {
        self.owner = owner
        self.render = render
        renderTracked()
        watch = FrameObservation(owner: owner, delivery: delivery, on: work, file: file, line: line) { [trigger] in
            trigger.generation
        } onChange: { [weak self] _ in
            self?.renderTracked()
        }
    }

    /// Stops the loop: no later render. Idempotent.
    public func cancel() {
        cancelled = true
        watch?.cancel()
        watch = nil
    }

    /// Whether ``cancel()`` ran.
    public var isCancelled: Bool { cancelled }

    private func renderTracked() {
        guard !cancelled else { return }
        renders += 1
        let trigger = trigger
        // view-observation-allow: the render's own reads; the FrameObservation on the trigger schedules the next render
        withObservationTracking {
            render()
        } onChange: { @Sendable in
            // main-hop-allow: models change on main, so this runs inline in the change's turn, where its cause is current
            MainDelivery().run { trigger.generation &+= 1 }
        }
    }
}

/// What an ``ObservationLoop``'s ``FrameObservation`` follows: bumped at the first change of what
/// the render read.
@MainActor @Observable
final class ObservationLoopTrigger {
    var generation: UInt64 = 0
}
