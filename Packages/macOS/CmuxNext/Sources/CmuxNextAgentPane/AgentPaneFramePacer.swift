public import AppKit
import CmuxNextWakeups

/// Display frames for ``AgentPaneFramePacer`` (the window's ``FrameScheduler``; a fake in tests).
@MainActor public protocol AgentPaneFrameTicks: AnyObject {
    /// Called once per display frame while active.
    var onTick: (@MainActor () -> Void)? { get set }
    func activate()
    func deactivate()
}

/// The one-shot fallback deadline of ``AgentPaneFramePacer`` (a ``MainDeadline``; a fake in tests).
@MainActor public protocol AgentPaneFallbackDeadline: AnyObject {
    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

/// Paces the transport's pushes to the page with no added latency when idle:
/// - No bridge call in flight: deliver at once, on the turn the frames arrived.
/// - A call in flight (until the page has run it): new frames wait and go together in the next
///   call, at most 512 frames each (``AgentPaneTransport/Limits``).
/// - Under load (a call finished less than one display frame after the previous one began): wait
///   for the next display frame, so a burst is at most one call per frame.
/// - The display link does not fire (an occluded or hidden window): after ``fallbackDelay`` the
///   frames go at once, and until a frame ticks again a later call goes on the next turn, or under
///   sustained load (this delivery and the one before found frames waiting within one frame
///   interval) one frame interval after the previous call began, on the fallback deadline. So
///   streaming and notifications keep arriving, one busy moment adds no wait, and a burst is still
///   at most one call per frame interval.
/// - A pane nobody can see (out of a window, hidden, or in a covered or minimized window): its
///   frames wait, and its page gets no call, until it shows (``visibilityChanged()``), or the frames
///   are ones the page waits on (``schedule(urgent:_:)``: a reply to its request, a turn's end, the
///   close, or a backlog). Each call woke the hidden page's web process: a streaming chat behind another tab
///   took 148 calls and 109 web-process sleep and wake cycles in two minutes (2026-10-21). Frames
///   the page waits on go at most every ``hiddenInterval``, on the fallback deadline. Twenty mostly
///   hidden chats each streaming a call per frame interval kept the main thread busy until the app
///   beachballed (2026-10-20).
///
/// Who can see the pane is its tab's ``VisibilityNode`` once the pane follows one (``follow(_:)``): one read, and a
/// flip delivers what it held, as Chromium's `WebContents` visibility drives its renderer
/// (content/public/browser/visibility.h). Its next-turn calls are `visible` tasks on the app's scheduler.
@MainActor public final class AgentPaneFramePacer: AgentPaneTransportPacer {
    /// One display frame at the slowest rate the pacer assumes.
    public static let frameInterval: TimeInterval = 1.0 / 120
    /// Longest wait for a display frame before the pacer treats the link as stalled.
    public static let fallbackDelay: Duration = .milliseconds(20)
    /// Shortest time between two calls to a pane nobody can see.
    public static let hiddenInterval: TimeInterval = 0.25

    private let frames: any AgentPaneFrameTicks
    private let fallback: any AgentPaneFallbackDeadline
    private let now: @MainActor () -> TimeInterval
    private let nextTurn: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private let isHidden: @MainActor () -> Bool
    /// The chat's tab node (``follow(_:)``), which says who can see the pane in place of ``isHidden``.
    private var node: VisibilityNode?
    private var nodeWatch: VisibilitySubscription?
    private var flush: (@MainActor @Sendable () -> AgentPaneFlush)?
    /// Frames arrived, or a capped flush left some, since the last call began.
    private var pending = false
    private(set) var inFlight = false
    private(set) var waitingForFrame = false
    /// The display link missed its frame; deliver on the next turn until it ticks again.
    private(set) var linkStalled = false
    private var nextTurnScheduled = false
    /// Stalled link under sustained load: the next call waits out the frame interval on the deadline.
    private(set) var waitingForInterval = false
    /// A hidden pane's next call waits out ``hiddenInterval`` on the deadline.
    private(set) var waitingWhileHidden = false
    /// A hidden pane's frames wait for it to show, or for frames its page waits on.
    private(set) var held = false
    /// The waiting frames include ones the page waits on (``schedule(urgent:_:)``) or a backlog.
    private var urgent = false
    /// The pane's ``AgentPaneVisibilityProbe``.
    private var probe: NSView?
    /// The last delivery found frames waiting within one frame interval of its call's start.
    private var loadedBefore = false
    private var lastCall: TimeInterval = -.infinity
    /// Calls made (tests).
    private(set) var calls = 0

    /// - Parameters:
    ///   - nextTurn: Runs a delivery on a later turn (the pane's: a `visible` task on the app's scheduler).
    public init(frames: any AgentPaneFrameTicks, fallback: any AgentPaneFallbackDeadline,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                nextTurn: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void,
                isHidden: @escaping @MainActor () -> Bool = { false }) {
        self.frames = frames
        self.fallback = fallback
        self.now = now
        self.nextTurn = nextTurn
        self.isHidden = isHidden
        frames.onTick = { [weak self] in self?.ticked() }
    }

    /// The pacer of a pane: its window's display frames, a ``MainDeadline`` fallback, and next-turn deliveries as
    /// `visible` tasks, all on the app's scheduling (``AgentPaneMainThread``).
    public convenience init(view: NSView, mainThread: AgentPaneMainThread) {
        let mainWork = mainThread.mainWork, owner = mainWork.board.owner("agent-pane.transport.next-turn")
        self.init(frames: AgentPaneWindowFrames(view: view), fallback: AgentPaneMainDeadline(deadlines: mainThread.deadlines),
                  nextTurn: { work in mainWork.post(.visible, owner: owner, work) },
                  isHidden: { [weak view] in view.map(Self.nobodySees) ?? true })
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        probe.onChange = { [weak self] in self?.visibilityChanged() }
        view.addSubview(probe)
        self.probe = probe
    }

    /// Whether nobody can see `view`: out of a window, hidden, or its window covered or minimized. Only for a pane
    /// that follows no tab node (``follow(_:)``).
    static func nobodySees(_ view: NSView) -> Bool {
        guard let window = view.window else { return true }
        // visibility-walk-allow: a pane no tab node holds (a standalone chat, a spare not adopted yet) has only
        // AppKit's view state; one walk per delivery, and none once the pane follows its tab's node
        return view.isHiddenOrHasHiddenAncestor || !window.occlusionState.contains(.visible)
    }

    /// Follows `node`, the chat's tab in the visibility tree: it says who can see the pane from now on, and a flip to
    /// visible delivers the frames held meanwhile. Nil goes back to the view's own state.
    public func follow(_ node: VisibilityNode?) {
        guard node !== self.node else { return }
        self.node = node
        nodeWatch = node?.subscribe(owner: "AgentPaneFramePacer") { [weak self] _ in self?.visibilityChanged() }
        visibilityChanged()
    }

    /// Nobody can see the pane: its tab node says so, or without one the injected test.
    private var nobodyCanSee: Bool {
        if let node { return !node.isVisible }
        return isHidden()
    }

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        schedule(urgent: false, flush)
    }

    public func schedule(urgent: Bool, _ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        self.flush = flush
        pending = true
        // Frames the page waits on stay waiting until a call takes them.
        self.urgent = self.urgent || urgent
        // Only frames the page waits on reach a held pacer (the socket wakes it for no others);
        // the rest go when the pane shows (``visibilityChanged()``).
        if held {
            guard urgent else { return }
            held = false
        }
        guard !inFlight, !waitingForFrame, !waitingForInterval, !nextTurnScheduled, !waitingWhileHidden else { return }
        call()
    }

    public func delivered() {
        inFlight = false
        guard pending else {
            loadedBefore = false
            return
        }
        let since = now() - lastCall + 1e-6 // a microsecond of rounding is a full frame
        let loaded = since < Self.frameInterval
        let sustained = loaded && loadedBefore
        loadedBefore = loaded
        if linkStalled, !sustained {
            scheduleNextTurn()
        } else if linkStalled {
            waitingForInterval = true
            fallback.schedule(after: .nanoseconds(Int64((Self.frameInterval - since) * 1e9))) { [weak self] in self?.intervalPassed() }
        } else if since >= Self.frameInterval {
            call()
        } else {
            waitingForFrame = true
            frames.activate()
            fallback.schedule(after: Self.fallbackDelay) { [weak self] in self?.missedFrame() }
        }
    }

    public func reset() {
        linkStalled = false
        flush = nil
        pending = false
        inFlight = false
        waitingForFrame = false
        nextTurnScheduled = false
        waitingForInterval = false
        waitingWhileHidden = false
        held = false
        urgent = false
        loadedBefore = false
        fallback.cancel()
        frames.deactivate()
    }

    /// Stops pacing (the pane closed).
    public func stop() {
        reset()
        probe?.removeFromSuperview()
        probe = nil
    }

    /// The pane may have come into sight: frames held while it was hidden go now.
    func visibilityChanged() {
        guard held || waitingWhileHidden, !nobodyCanSee else { return }
        held = false
        if waitingWhileHidden {
            waitingWhileHidden = false
            fallback.cancel()
        }
        call()
    }

    private func call() {
        guard let flush, pending else { return }
        // Every path here has the deadline free: none of the waits that use it is on.
        if nobodyCanSee {
            guard urgent else {
                held = true
                return
            }
            let wait = Self.hiddenInterval - (now() - lastCall)
            if wait > 0.001 {
                waitingWhileHidden = true
                fallback.schedule(after: .nanoseconds(Int64(wait * 1e9))) { [weak self] in self?.hiddenIntervalPassed() }
                return
            }
        }
        // A late `delivered()` can take a hidden wait's deadline; the flag goes with this call.
        waitingWhileHidden = false
        pending = false
        urgent = false
        inFlight = true
        lastCall = now()
        let result = flush()
        if result.delivered { calls += 1 } else { inFlight = false }
        // A capped flush leaves frames: they go when this call is done, or next turn without one.
        // They are a backlog, which a hidden pane gets too.
        if result.more {
            pending = true
            urgent = true
            if !inFlight { scheduleNextTurn() }
        }
    }

    private func ticked() {
        linkStalled = false
        if waitingForInterval {
            waitingForInterval = false
            fallback.cancel()
            frames.deactivate()
            return call()
        }
        guard waitingForFrame else {
            frames.deactivate()
            return
        }
        waitingForFrame = false
        fallback.cancel()
        call()
    }

    private func hiddenIntervalPassed() {
        guard waitingWhileHidden else { return }
        waitingWhileHidden = false
        call()
    }

    private func intervalPassed() {
        guard waitingForInterval else { return }
        waitingForInterval = false
        call()
    }

    private func missedFrame() {
        guard waitingForFrame else { return }
        waitingForFrame = false
        linkStalled = true
        call()
    }

    private func scheduleNextTurn() {
        guard !nextTurnScheduled else { return }
        nextTurnScheduled = true
        // Keep the link asked for frames, so a window that shows again leaves the fallback.
        frames.activate()
        nextTurn { [weak self] in
            guard let self else { return }
            self.nextTurnScheduled = false
            if !self.inFlight { self.call() }
        }
    }
}
