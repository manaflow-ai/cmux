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
/// - A pane whose page the page lifecycle froze (``pageDidFreeze()``): no call, no deadline and no
///   display-frame request at all, whatever arrives, as Blink runs no freezable task while a page is
///   frozen (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_task_queue.h,
///   `can_be_frozen`). The thaw (``pageDidThaw()``) sends what waited in one call, in the thaw's turn:
///   the show thaws before the page is visible, so that call joins the router's held batch.
///
/// Whether the pane is seen comes from the visibility tree (``AgentPaneVisibilityProbe``: its node
/// under the window's, which follows occlusion, minimizing and app hide once per window), and its
/// frozen state from the page lifecycle (``AgentPageLifecycleTarget``). Its next-turn calls are `visible` tasks
/// and its fallback a `visible` ``MainDeadline``, on the app's scheduling (``AgentPaneMainThread``): what a shown
/// chat streams is what it shows, and no input of the person's caused it.
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
    /// The page lifecycle froze the pane's page: frames wait for the thaw, with nothing armed.
    private(set) var frozen = false
    public var pageFrozen: Bool { frozen }
    /// The page thawed: its next call goes even to a pane nobody sees (``pageDidThaw()``).
    private var thawCall = false
    /// The pane's ``AgentPaneVisibilityProbe``.
    private var probe: AgentPaneVisibilityProbe?
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

    /// The pacer of a pane: its window's display frames, a ``MainDeadline`` fallback and next-turn deliveries as
    /// `visible` tasks on the app's scheduling, and whether the pane is seen from its probe's node in the
    /// visibility tree (O(1), no view walk).
    public convenience init(view: NSView, mainThread: AgentPaneMainThread) {
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        let mainWork = mainThread.mainWork, owner = mainWork.board.owner("agent-pane.transport.next-turn")
        self.init(frames: AgentPaneWindowFrames(view: view), fallback: AgentPaneMainDeadline(deadlines: mainThread.deadlines),
                  nextTurn: { work in mainWork.post(.visible, owner: owner, work) },
                  isHidden: { [weak probe] in !(probe?.isSeen ?? false) })
        probe.onChange = { [weak self] in self?.visibilityChanged() }
        view.addSubview(probe)
        self.probe = probe
    }

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        schedule(urgent: false, flush)
    }

    public func schedule(urgent: Bool, _ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        self.flush = flush
        pending = true
        // Frames the page waits on stay waiting until a call takes them.
        self.urgent = self.urgent || urgent
        // A frozen page takes nothing, urgent or not: the thaw sends it all (``pageDidThaw()``).
        if frozen { return }
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
        guard pending, !frozen else {
            loadedBefore = false
            thawCall = false
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
        thawCall = false
        fallback.cancel()
        frames.deactivate()
    }

    /// Stops pacing (the pane closed).
    public func stop() {
        reset()
        frozen = false
        probe?.removeFromSuperview()
        probe = nil
    }

    /// The page lifecycle froze the pane's page: from now on until ``pageDidThaw()`` the pacer makes no
    /// call and arms no deadline and no display frame. What waits stays waiting; a call in flight ends
    /// with ``delivered()`` and starts no next one.
    public func pageDidFreeze() {
        guard !frozen else { return }
        frozen = true
        thawCall = false
        waitingForFrame = false
        waitingForInterval = false
        waitingWhileHidden = false
        held = false
        fallback.cancel()
        frames.deactivate()
    }

    /// The page runs again (it shows, a turn started on it, or a call needed it): what waited goes now
    /// in one call, hidden or not. The show thaws before the page is visible and before the router
    /// sends what it held, so this call joins that batch; later frames follow the usual rules. A call
    /// still in flight from before the freeze goes first: the thaw's call follows its ``delivered()``.
    public func pageDidThaw() {
        guard frozen else { return }
        frozen = false
        // Only frames that waited through the freeze make a thaw call; with none, the hidden hold stays.
        thawCall = pending
        guard !inFlight, !nextTurnScheduled else { return }
        call()
    }

    /// The pane may have come into sight: frames held while it was hidden go now.
    func visibilityChanged() {
        // A page that shows runs: the page view thaws before it shows, whichever path showed it.
        if frozen, !isHidden() { return pageDidThaw() }
        guard held || waitingWhileHidden, !isHidden() else { return }
        held = false
        if waitingWhileHidden {
            waitingWhileHidden = false
            fallback.cancel()
        }
        call()
    }

    private func call() {
        // The thaw's call is the first one after it, made or not: a hidden pane takes only that one.
        let thawing = thawCall
        thawCall = false
        guard !frozen, let flush, pending else { return }
        // Every path here has the deadline free: none of the waits that use it is on.
        if !thawing, isHidden() {
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
        if frozen { return frames.deactivate() }
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
