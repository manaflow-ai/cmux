public import AppKit
import QuartzCore

/// One frame delivered to a ``FrameClient``: Chrome's `viz::BeginFrameArgs`
/// (components/viz/common/frame_sinks/begin_frame_args.h), whose `frame_time`, `deadline`,
/// `interval` and `sequence_number` are ``timestamp``, ``targetTimestamp``, ``refreshInterval``
/// and ``sequence``.
public struct FrameTick: Sendable {
    /// Display-link time of this frame (CACurrentMediaTime base).
    public var timestamp: CFTimeInterval
    /// Seconds since the previous frame, clamped to 1/240...1/30.
    public var elapsed: Double
    /// Seconds since the previous frame, unclamped (frame-pacing probes).
    public var rawElapsed: Double
    /// The display's refresh period; nil for a synthesized (stalled) frame.
    public var refreshInterval: Double?
    /// When the frame this tick builds is shown (the link's `targetTimestamp`, CACurrentMediaTime base).
    /// A synthesized (stalled) frame is shown one link interval after it starts, as Chrome's synthetic
    /// sources set `deadline = frame_time + interval` (`BackToBackBeginFrameSource::OnTimerTick`,
    /// components/viz/common/frame_sinks/begin_frame_source.cc). Sample a presented value (a spring, a
    /// `MotionPath`) at this time, not at `CACurrentMediaTime()`: the main thread runs the tick late.
    public var targetTimestamp: CFTimeInterval
    /// The frame's number on its scheduler, from 1, one more each frame (stalled frames too): a gap
    /// between two ticks a client saw is a frame it missed.
    public var sequence: UInt64

    /// The interval a frame with no known refresh period is shown after (60 Hz).
    public static let defaultRefreshInterval: Double = 1.0 / 60.0

    /// A tick; `targetTimestamp` defaults to `timestamp` plus the refresh period
    /// (``defaultRefreshInterval`` when `refreshInterval` is nil).
    public init(timestamp: CFTimeInterval, elapsed: Double, rawElapsed: Double, refreshInterval: Double?,
                targetTimestamp: CFTimeInterval? = nil, sequence: UInt64 = 0) {
        self.timestamp = timestamp
        self.elapsed = elapsed
        self.rawElapsed = rawElapsed
        self.refreshInterval = refreshInterval
        self.targetTimestamp = targetTimestamp ?? timestamp + (refreshInterval ?? Self.defaultRefreshInterval)
        self.sequence = sequence
    }
}

/// A reason to receive frames: an animation, a drag autoscroll, a settle
/// wait. Active clients keep their scheduler's display link running; the
/// tick returns false to go idle, and the link stops with the last client.
///
/// A client made with a `visibleOnly` node draws only for someone: while the node is not
/// ``VisibilityNode/wantsFrames`` it stays active but leaves its scheduler, so it is never ticked,
/// and its window's link drops when it was the only client. It joins again, and ticks from the next
/// frame, when the node is seen or captured. Chrome stops a hidden widget's BeginFrames the same way:
/// `RenderWidgetHostViewMac::WasOccluded` hides the widget
/// (content/browser/renderer_host/render_widget_host_view_mac.mm), and a hidden `cc::Scheduler`
/// stops wanting BeginFrames (`SchedulerStateMachine::BeginFrameNeeded`, cc/scheduler/scheduler_state_machine.cc).
@MainActor
public final class FrameClient {
    /// The client's name in the wakeup ledger, the board and the watchdog's records.
    public let owner: String
    /// Visible motion (springs, autoscroll); false for batch work such as
    /// the daemon store drain, which the busy watchdog must not excuse.
    public let isAnimation: Bool
    /// The client's priority class: ``MainWorkClass/frame`` (every frame, unbudgeted) unless the
    /// client was made with ``init(owner:budgeted:on:onFrame:)``.
    public let workClass: MainWorkClass
    /// How often it needs frames: its display's link runs at the highest rate of the active clients
    /// on it (``FrameRate``). ``FrameRate/motion`` unless the client was made with another: every
    /// key-to-frame client, batch and probe stays motion. An ambient rate (``FrameRate/isAmbient``) is
    /// opt-in and owner-reviewed: Energy Saver caps it at ``EnergyPolicy/ambientMaxFPS`` and it waits
    /// while the displays sleep (FrameScheduler+Energy.swift).
    public let rate: FrameRate
    /// The node whose visibility gates its ticks (``VisibilityNode/wantsFrames``); nil: it ticks
    /// whether or not anyone sees it.
    public let visibleOnly: VisibilityNode?
    private let onFrame: @MainActor (FrameTick) -> Bool
    private let resolve: @MainActor () -> FrameScheduler
    private weak var scheduler: FrameScheduler?
    /// The launch phases that enable a budgeted client's class (its ``MainWorkScheduler``'s); nil
    /// for frame and input clients, which are never held.
    private let startup: StartupPhase?
    /// True while an active client waits for the phase that opens its class.
    private var waitingForStartup = false
    /// The changes of ``visibleOnly``'s ``VisibilityNode/wantsFrames`` (a flip or a capture vote):
    /// made on the first activation and kept for the client's life, so a one-shot client activated
    /// every frame does no subscription work. An idle client ignores them.
    private var visibilityWatch: VisibilitySubscription?
    /// Whether the client wants frames (between ``activate()`` and the tick that returns false).
    public private(set) var isActive = false

    /// Whether an active client is off its scheduler because nobody sees its ``visibleOnly`` node.
    public var isParked: Bool { isActive && !isSeen }

    /// `onFrame` returns true to keep ticking. The client ticks on the
    /// scheduler `resolve` returns when it activates, at `rate` or faster, and only while
    /// `visibleOnly` (when given) is seen or captured.
    public init(owner: String, isAnimation: Bool = true, rate: FrameRate = .motion, visibleOnly: VisibilityNode? = nil,
                scheduler resolve: @escaping @MainActor () -> FrameScheduler,
                onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.owner = owner
        self.isAnimation = isAnimation
        self.workClass = .frame
        self.rate = rate
        self.visibleOnly = visibleOnly
        self.resolve = resolve
        self.onFrame = onFrame
        startup = nil
    }

    /// A batch client of a budgeted class (``MainWorkClass/isBudgeted``) on the app's one
    /// ``MainWorkScheduler``: it ticks after the higher classes, only when ``MainFrameBudget/mayRun(_:)``
    /// lets its class run, and in turn with the other clients of its class; otherwise it stays
    /// active and ticks on the next frame. `onFrame` gets the budget: it runs its work through
    /// ``MainFrameBudget/run(_:owner:posted:_:)``, one task at a time, and returns true to tick again while
    /// work is left. The client holds `work`: it never falls back to another scheduler.
    ///
    /// While `work`'s ``StartupPhase`` does not admit the class (background while launching), an
    /// activated client stays off the frame scheduler: its work waits in its queue, and the phase
    /// change attaches it, so it ticks from the next frame on.
    public init(owner: String, budgeted workClass: BudgetedWorkClass, on work: MainWorkScheduler,
                onFrame: @escaping @MainActor (FrameTick, MainFrameBudget) -> Bool) {
        self.owner = owner
        self.isAnimation = false
        self.workClass = workClass.workClass
        self.rate = .motion
        visibleOnly = nil
        let frames = work.frames, budget = work.budget
        self.resolve = { frames }
        self.onFrame = { tick in onFrame(tick, budget) }
        startup = work.startup
    }

    /// The input stage of `scheduler`'s frames (``FrameInputCoalescer``): it ticks before the frame
    /// clients, so they see the frame's input, and a frame client it activates ticks in the same frame.
    /// Not visible motion: the busy watchdog does not excuse it.
    init(inputStageOf scheduler: FrameScheduler, owner: String, onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.owner = owner
        self.isAnimation = false
        self.workClass = .input
        self.rate = .motion
        visibleOnly = nil
        self.resolve = { [weak scheduler] in scheduler ?? .app }
        self.onFrame = onFrame
        startup = nil
    }

    /// A client of `view`'s window (``FrameScheduler/app`` while it has none).
    public convenience init(owner: String, rate: FrameRate = .motion, visibleOnly: VisibilityNode? = nil, view: NSView,
                            onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, rate: rate, visibleOnly: visibleOnly, scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app },
                  onFrame: onFrame)
    }

    /// A client of a fixed scheduler (``FrameScheduler/app`` once that scheduler is gone,
    /// as for a view client without a window).
    public convenience init(owner: String, isAnimation: Bool = true, rate: FrameRate = .motion,
                            visibleOnly: VisibilityNode? = nil, on scheduler: FrameScheduler,
                            onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, isAnimation: isAnimation, rate: rate, visibleOnly: visibleOnly, scheduler: { [weak scheduler] in scheduler ?? .app },
                  onFrame: onFrame)
    }

    /// Starts ticking (no effect while active); a budgeted client whose class the launch holds
    /// starts at the phase change, and a client whose ``visibleOnly`` node nobody sees starts when
    /// someone does.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        watchVisibility()
        if let startup, !startup.admits(workClass) { return waitForStartup(startup) }
        guard isSeen else { return }
        attach()
    }

    /// Whether someone sees what it draws: its ``visibleOnly`` node wants frames, or it has none.
    private var isSeen: Bool { visibleOnly?.wantsFrames ?? true }

    private func watchVisibility() {
        guard let visibleOnly, visibilityWatch == nil else { return }
        visibilityWatch = visibleOnly.subscribeRendering(owner: owner) { [weak self] _ in self?.visibilityDidChange() }
    }

    /// Its node flipped or a capture vote came or went: an unseen client leaves its scheduler (whose
    /// link drops with its last client), a seen one joins its window's scheduler again.
    private func visibilityDidChange() {
        guard isActive, !waitingForStartup else { return }
        if isSeen {
            if scheduler == nil { attach() }
        } else if let scheduler {
            self.scheduler = nil
            scheduler.deactivate(self)
        }
    }

    private func attach() {
        let target = resolve()
        scheduler = target
        target.activate(self)
    }

    private func waitForStartup(_ startup: StartupPhase) {
        guard !waitingForStartup else { return }
        waitingForStartup = true
        startup.whenReached(workClass.startupOpening) { [weak self] in
            guard let self else { return }
            waitingForStartup = false
            if isActive, scheduler == nil, isSeen { attach() }
        }
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

    /// Delivers a frame (its scheduler fires only active clients it still holds); false when the
    /// client went idle.
    func fire(_ tick: FrameTick) -> Bool {
        if onFrame(tick) && isActive { return true }
        isActive = false
        scheduler = nil
        return false
    }

    // No deinit. An active client is held by its scheduler, so a client is only released once it
    // is idle or parked (its visibility subscriptions, held only by it, go with it), and owners
    // deactivate before they let go. An `isolated deinit` here hopped through the Swift runtime on
    // every release and trapped when a layout view left its window (cx-t7hu).
}
