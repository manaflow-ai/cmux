public import AppKit
import CmuxNextWakeups

/// Display frames for ``AgentPaneFramePacer`` (the window's ``FrameScheduler``; a fake in tests).
@MainActor public protocol AgentPaneFrameTicks: AnyObject {
    /// Called once per display frame while active.
    var onTick: (@MainActor () -> Void)? { get set }
    func activate()
    func deactivate()
}

/// The one-shot fallback deadline of ``AgentPaneFramePacer`` (a ``DemandTimer``; a fake in tests).
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
@MainActor public final class AgentPaneFramePacer: AgentPaneTransportPacer {
    /// One display frame at the slowest rate the pacer assumes.
    public static let frameInterval: TimeInterval = 1.0 / 120
    /// Longest wait for a display frame before the pacer treats the link as stalled.
    public static let fallbackDelay: Duration = .milliseconds(20)

    private let frames: any AgentPaneFrameTicks
    private let fallback: any AgentPaneFallbackDeadline
    private let now: @MainActor () -> TimeInterval
    private let nextTurn: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
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
    /// The last delivery found frames waiting within one frame interval of its call's start.
    private var loadedBefore = false
    private var lastCall: TimeInterval = -.infinity
    /// Calls made (tests).
    private(set) var calls = 0

    public init(frames: any AgentPaneFrameTicks, fallback: any AgentPaneFallbackDeadline,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                nextTurn: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
                    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
                }) {
        self.frames = frames
        self.fallback = fallback
        self.now = now
        self.nextTurn = nextTurn
        frames.onTick = { [weak self] in self?.ticked() }
    }

    /// The pacer of a pane: its window's display frames, a ``DemandTimer`` fallback.
    public convenience init(view: NSView) {
        self.init(frames: AgentPaneWindowFrames(view: view), fallback: AgentPaneDemandDeadline())
    }

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        self.flush = flush
        pending = true
        guard !inFlight, !waitingForFrame, !waitingForInterval, !nextTurnScheduled else { return }
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
        loadedBefore = false
        fallback.cancel()
        frames.deactivate()
    }

    /// Stops pacing (the pane closed).
    public func stop() { reset() }

    private func call() {
        guard let flush, pending else { return }
        pending = false
        inFlight = true
        lastCall = now()
        let result = flush()
        if result.delivered { calls += 1 } else { inFlight = false }
        // A capped flush leaves frames: they go when this call is done, or next turn without one.
        if result.more {
            pending = true
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
