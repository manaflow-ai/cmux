public import AppKit
import QuartzCore

/// One frame delivered to a ``FrameClient``.
public struct FrameTick: Sendable {
    /// Display-link time of this frame (CACurrentMediaTime base).
    public var timestamp: CFTimeInterval
    /// Seconds since the previous frame, clamped to 1/240...1/30.
    public var elapsed: Double
    /// Seconds since the previous frame, unclamped (frame-pacing probes).
    public var rawElapsed: Double
    /// The display's refresh period; nil for a synthesized (stalled) frame.
    public var refreshInterval: Double?
}

/// A reason to receive frames: an animation, a drag autoscroll, a settle
/// wait. Active clients keep their scheduler's display link running; the
/// tick returns false to go idle, and the link stops with the last client.
@MainActor
public final class FrameClient {
    public let owner: String
    /// Visible motion (springs, autoscroll); false for batch work such as
    /// the daemon store drain, which the busy watchdog must not excuse.
    public let isAnimation: Bool
    /// The client's priority class: ``MainWorkClass/frame`` (every frame, unbudgeted) unless the
    /// client was made with ``init(owner:budgeted:on:onFrame:)``.
    public let workClass: MainWorkClass
    private let onFrame: @MainActor (FrameTick) -> Bool
    private let resolve: @MainActor () -> FrameScheduler
    private weak var scheduler: FrameScheduler?
    public private(set) var isActive = false

    /// `onFrame` returns true to keep ticking. The client ticks on the
    /// scheduler `resolve` returns when it activates.
    public init(owner: String, isAnimation: Bool = true, scheduler resolve: @escaping @MainActor () -> FrameScheduler,
                onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.owner = owner
        self.isAnimation = isAnimation
        self.workClass = .frame
        self.resolve = resolve
        self.onFrame = onFrame
    }

    /// A batch client of a budgeted class (``MainWorkClass/isBudgeted``) on the app's one
    /// ``MainWorkScheduler``: it ticks after the higher classes, only when ``MainFrameBudget/mayRun(_:)``
    /// lets its class run, and in turn with the other clients of its class; otherwise it stays
    /// active and ticks on the next frame. `onFrame` gets the budget: it runs its work through
    /// ``MainFrameBudget/run(_:owner:_:)``, one task at a time, and returns true to tick again while
    /// work is left. The client holds `work`: it never falls back to another scheduler.
    public init(owner: String, budgeted workClass: BudgetedWorkClass, on work: MainWorkScheduler,
                onFrame: @escaping @MainActor (FrameTick, MainFrameBudget) -> Bool) {
        self.owner = owner
        self.isAnimation = false
        self.workClass = workClass.workClass
        let frames = work.frames, budget = work.budget
        self.resolve = { frames }
        self.onFrame = { tick in onFrame(tick, budget) }
    }

    /// A client of `view`'s window (``FrameScheduler/app`` while it has none).
    public convenience init(owner: String, view: NSView, onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }, onFrame: onFrame)
    }

    /// A client of a fixed scheduler (``FrameScheduler/app`` once that scheduler is gone,
    /// as for a view client without a window).
    public convenience init(owner: String, isAnimation: Bool = true, on scheduler: FrameScheduler,
                            onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, isAnimation: isAnimation, scheduler: { [weak scheduler] in scheduler ?? .app }, onFrame: onFrame)
    }

    /// Starts ticking (no effect while active).
    public func activate() {
        guard !isActive else { return }
        isActive = true
        let target = resolve()
        scheduler = target
        target.activate(self)
    }

    /// Stops ticking.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        scheduler?.deactivate(self)
        scheduler = nil
    }

    /// The scheduler went away: idle without calling back.
    func detach() {
        isActive = false
        scheduler = nil
    }

    /// Delivers a frame; false when the client went idle.
    func fire(_ tick: FrameTick) -> Bool {
        guard isActive else { return false }
        if onFrame(tick) && isActive { return true }
        isActive = false
        scheduler = nil
        return false
    }

    // No deinit. An active client is held by its scheduler, so a client is only released once it
    // is idle, and owners deactivate before they let go. An `isolated deinit` here hopped through
    // the Swift runtime on every release and trapped when a layout view left its window (cx-t7hu).
}
