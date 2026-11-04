public import AppKit
import CmuxNextDesignTokens
import CmuxNextWakeups

/// A window's live-resize drags as input of its next display frame (FRAME OWNER REFACTOR S7,
/// `motion.frameOwner.liveResize`). On macOS 26 and 27 AppKit resizes a window from each drag event the window gets
/// (`-[NSWindow sendEvent:]` -> its resize gesture -> `setFrame(_:display:)`), and each `setFrame` lays the whole view
/// tree out in that event's turn: with drags queued behind a long turn, the window resized and laid out once per event,
/// back to back, and its frame ticks came 44-62 ms apart (px-window-resize-4, 52-67 dropped refreshes per film).
///
/// Now a window applies at most one drag per display frame. The first drag of a display frame goes to AppKit in its own
/// turn, as with the switch off, so it costs no latency. A drag that comes after one was applied in the same display
/// frame is kept, the newest replacing the one before, and the window's next frame tick gives it to AppKit as an input
/// client (it ticks before the springs and probes): one window frame, one layout pass and one commit per display frame.
/// Input changes the model in its own turn when the frame has room, and the rest coalesces to the frame: Chrome aligns
/// continuous input to the begin-frame and pays up to a refresh of latency for it, and a drag that waits for the tick
/// pays it too, so the drags of a frame that has room do not wait. (A one-film-per-arm judge of the switch films,
/// ab-s7-sw-63b290e, started this change; it is not proof by itself: whole-window lateness varies between films of one
/// app.) Any other event of the
/// window (the release, a key, a modifier change) gives the waiting drag to AppKit first, in its own turn, so the release
/// lands where the pointer let go and nothing reorders.
///
/// The switch is read at a resize's first drag and kept until the next press or release, so one resize never mixes the
/// two paths. A drag outside a live resize (a text selection, a tab drag) goes on in its own turn.
@MainActor
public final class LiveResizeDragInput {
    /// Frame ticks the client keeps after the last drag, so a slow drag does not make the display link again for each
    /// event (about 67 ms at 120 Hz, as a divider drag's `panTickTail`).
    static let tickTail = 8

    private weak var window: NSWindow?
    /// Gives an event to AppKit (the window's `super.sendEvent`).
    private let deliver: @MainActor (NSEvent) -> Void
    /// A frame of the live resize was applied (``applyingFrame(_:)``): the window's overlay sends its page update.
    private let frameApplied: @MainActor () -> Void
    /// The newest drag that waits for the frame tick, and the pointer travel of the drags it replaced.
    private var waiting: (event: NSEvent, dx: CGFloat, dy: CGFloat)?
    /// The switch for the resize in progress, read at its first drag; nil between resizes.
    private var latched: Bool?
    /// The S7 diagnostics read with the switch (`motion.frameOwner.liveResize.pageHold` and `.trackerHold`).
    private var latchedHolds = (page: true, tracker: true)
    /// `motion.frameOwner.liveResize.atEvent`, read with the switch: coalesce at input instead of on the frame tick.
    private var latchedAtEvent = false
    /// `motion.frameOwner.liveResize.pageAfterCommit`, read with the switch (a diagnostic; DEBUG and bench builds).
    private var latchedPageAfterCommit = false
    /// The tracker hold also covers the theme frame (`motion.frameOwner.liveResize.holdsToRoot`, DEBUG and bench only:
    /// ``FollowedViews`` ignores it in other builds).
    private var latchedHoldsToRoot = false
    /// The followed views' frame notices and the page update wait for the commit of the last applied `setFrame`.
    private var heldForCommit = false
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Tells the frame tick that the held `setFrame`'s commit happened (``CommitWitness``).
    private lazy var commitWitness = CommitWitness()
    #endif
    /// Whether a newer drag waits in the application's event queue (a peek, no dequeue; tests replace it).
    var newerDragQueued: @MainActor () -> Bool = { LiveResizeDragInput.applicationHasQueuedDrag() }
    /// A drag was applied in the display frame that runs now (since the last frame tick): a drag that comes now waits
    /// for the next tick. A tick starts a display frame; it applies the waiting drag, if any. It is the frame's, not the
    /// resize's: a press and release do not clear it, so a new resize in the same display frame as the last applied drag
    /// waits for the tick too (at most one tree layout per display frame).
    private var appliedThisFrame = false
    private var ticksLeft = 0
    private lazy var client = FrameClient(owner: "LiveResize.drag", isAnimation: false, input: true, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    /// This live resize applies at most one drag per display frame: `motion.frameOwner.liveResize` read at its first
    /// drag and kept until the release. What else S7 changes in a live resize (``LiveResizePageUpdates``, ``FollowedViews``) follows it.
    public var isFramed: Bool { latched == true }
    /// This live resize sends one page update per applied drag (``LiveResizePageUpdates``).
    public var holdsPageUpdates: Bool { isFramed && latchedHolds.page }
    /// This live resize holds the followed views' frame notices until each `setFrame` returns (``FollowedViews``).
    public var holdsTrackerNotices: Bool { isFramed && latchedHolds.tracker }
    /// The page update and the page tracker wait for the commit of this resize's last applied `setFrame`, and go at the
    /// first frame tick after it (`motion.frameOwner.liveResize.pageAfterCommit`, a diagnostic).
    public var holdsUntilCommit: Bool { heldForCommit }

    /// Drags given to AppKit from a frame tick and drags a newer one replaced, cumulative (diagnostics and tests).
    public private(set) var tickDeliveries = 0, replaced = 0

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.motion`'s timing of each frame of the resize, and the drag AppKit applies next: its event time and whether
    /// a frame tick gave it.
    private lazy var probe = LiveResizeFrameProbe()
    private var nextApplied: (eventTime: TimeInterval, atTick: Bool)?
    #endif

    /// `deliver` gives an event to AppKit for `window` (its `super.sendEvent`); `frameApplied` runs after each `setFrame`
    /// of its live resize (``applyingFrame(_:)``).
    public init(window: NSWindow, frameApplied: @escaping @MainActor () -> Void = {}, deliver: @escaping @MainActor (NSEvent) -> Void) {
        self.window = window
        self.frameApplied = frameApplied
        self.deliver = deliver
    }

    /// Whether `event` (sent to this input's window) waits for the frame tick. False: the caller sends it now (the first
    /// drag of a display frame, or not a live-resize drag); a waiting drag has gone to AppKit first.
    public func takes(_ event: NSEvent) -> Bool { // perf-hot: 0.5ms drag-frame
        guard event.type == .leftMouseDragged, let window, Motion.isInLiveResize(window) else {
            flush()
            switch event.type {
            case .leftMouseDown, .leftMouseUp:
                releaseAfterCommit() // the resize ends: what waits for a commit goes now, before AppKit hears the release
                latched = nil
            default: break
            }
            return false
        }
        if latched == nil {
            latchedHolds = (MotionTunables.frameOwnerLiveResizePageHold.value, MotionTunables.frameOwnerLiveResizeTrackerHold.value)
            latchedAtEvent = MotionTunables.frameOwnerLiveResizeAtEvent.value
            latchedPageAfterCommit = MotionTunables.frameOwnerLiveResizePageAfterCommit.value
            latchedHoldsToRoot = MotionTunables.frameOwnerLiveResizeHoldsToRoot.value
        }
        let on = latched ?? MotionTunables.frameOwnerLiveResize.value
        latched = on
        guard on else {
            noteApplying(event, atTick: false)
            return false
        }
        if latchedAtEvent { return takeAtEvent(event) }
        ticksLeft = Self.tickTail
        client.activate()
        // The display frame's first drag: AppKit applies it in this turn.
        guard appliedThisFrame else {
            appliedThisFrame = true
            noteApplying(event, atTick: false)
            return false
        }
        if let waiting {
            replaced += 1
            self.waiting = (event, waiting.dx + waiting.event.deltaX, waiting.dy + waiting.event.deltaY)
        } else {
            waiting = (event, 0, 0)
        }
        return true
    }

    /// Coalescing at input (`motion.frameOwner.liveResize.atEvent`): the drag goes to AppKit in this event turn with the
    /// travel of the drags it replaced, unless a newer drag already waits in the event queue; then it waits for it.
    private func takeAtEvent(_ event: NSEvent) -> Bool {
        if let waiting {
            replaced += 1
            self.waiting = (event, waiting.dx + waiting.event.deltaX, waiting.dy + waiting.event.deltaY)
        } else {
            waiting = (event, 0, 0)
        }
        guard !newerDragQueued() else { return true }
        flush()
        return true
    }

    /// A drag in the application's queue, read without running the run loop's sources: a mode with no sources only
    /// looks at the events AppKit already took from the window server.
    static func applicationHasQueuedDrag() -> Bool {
        NSApp?.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: Self.peekMode, dequeue: false) != nil
    }

    private static let peekMode = RunLoop.Mode("com.cmux.liveResize.peek")

    /// A `setFrame` of the window in its live resize (`apply`): when this resize's drags wait for the frame tick, the
    /// views another window follows post their frame notices once, after it, with the final geometry (``FollowedViews``);
    /// then `frameApplied` runs.
    public func applyingFrame(_ apply: () -> Void) {
        let waitsForCommit = holdsForCommitNow
        #if DEBUG || CMUX_BENCH_HOOKS
        let applied = nextApplied
        nextApplied = nil
        let frame = window.flatMap { probe.frameWillApply(in: $0, eventTime: applied?.eventTime, atTick: applied?.atTick == true) }
        #endif
        if waitsForCommit, let window {
            holdForCommit(in: window)
            apply()
            setFrameDidReturn()
        } else if holdsTrackerNotices, let window {
            FollowedViews.of(window).holdingFrameNotices(throughFrameView: latchedHoldsToRoot) {
                apply()
                setFrameDidReturn()
            }
        } else {
            apply()
            setFrameDidReturn()
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        if let frame { probe.frameDidApply(frame) }
        #endif
        guard !waitsForCommit else { return }
        frameApplied()
        #if DEBUG || CMUX_BENCH_HOOKS
        probe.pageUpdatePosted()
        #endif
    }

    /// `super.setFrame` returned, before held frame notices go: the probe's step there (nothing in a shipped build).
    private func setFrameDidReturn() {
        #if DEBUG || CMUX_BENCH_HOOKS
        probe.setFrameDidReturn()
        #endif
    }

    /// Whether this `setFrame`'s page update and tracker notices wait for its commit (the diagnostic, DEBUG and bench).
    private var holdsForCommitNow: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        return latchedPageAfterCommit && isFramed
        #else
        return false
        #endif
    }

    /// Holds the followed views' notices across the turn and marks the turn's transaction; the frame tick after the
    /// commit lets them go (``releaseAfterCommit()``).
    private func holdForCommit(in window: NSWindow) {
        #if DEBUG || CMUX_BENCH_HOOKS
        FollowedViews.of(window).beginHold(throughFrameView: latchedHoldsToRoot)
        heldForCommit = true
        if let root = window.contentView?.layer { commitWitness.attach(to: root) }
        commitWitness.arm()
        ticksLeft = Self.tickTail
        client.activate()
        #endif
    }

    /// The tracker hears the followed views (the final geometry, once each) and the overlay sends its held page update.
    private func releaseAfterCommit() {
        guard heldForCommit else { return }
        heldForCommit = false
        if let window { FollowedViews.of(window).endHold() }
        frameApplied()
    }

    /// The window's didMove (its delegate) in its live resize: the probe notes when it came (DEBUG and bench builds).
    public func windowDidMove() {
        #if DEBUG || CMUX_BENCH_HOOKS
        probe.windowDidMove()
        #endif
    }

    /// The window's didResize (its delegate): the probe notes whether AppKit already committed (DEBUG and bench builds).
    public func windowDidResize() {
        #if DEBUG || CMUX_BENCH_HOOKS
        probe.windowDidResize()
        #endif
    }

    /// The window closes: a waiting drag goes with it, and no more frames.
    public func windowWillClose() {
        releaseAfterCommit()
        waiting = nil
        latched = nil
        appliedThisFrame = false
        client.deactivate()
    }

    /// The window's frame tick starts a display frame: the waiting drag goes to AppKit, which resizes the window and lays
    /// it out in this tick, and that is the frame's drag. With none waiting, the frame's first drag goes in its own turn.
    private func tick() -> Bool { // perf-hot: 4ms motion-frame
        #if DEBUG || CMUX_BENCH_HOOKS
        if heldForCommit, commitWitness.committed { releaseAfterCommit() }
        #endif
        // Coalescing at input applies no drag at the tick; it ticks only for a release that waits for a commit.
        if latchedAtEvent {
            ticksLeft -= 1
            return ticksLeft > 0 || heldForCommit
        }
        appliedThisFrame = waiting != nil
        if waiting != nil {
            tickDeliveries += 1
            flush(atTick: true)
            ticksLeft = Self.tickTail
            return true
        }
        ticksLeft -= 1
        return ticksLeft > 0 || heldForCommit
    }

    private func flush(atTick: Bool = false) {
        guard let waiting else { return }
        self.waiting = nil
        let event = Self.carrying(waiting.event, dx: waiting.dx, dy: waiting.dy)
        noteApplying(event, atTick: atTick)
        deliver(event)
    }

    /// AppKit applies `event` next (``LiveResizeFrameProbe``; nothing in a shipped build).
    private func noteApplying(_ event: NSEvent, atTick: Bool) {
        #if DEBUG || CMUX_BENCH_HOOKS
        nextApplied = (event.timestamp, atTick)
        #endif
    }

    /// `event` with the pointer travel of the drags it replaced added to its own deltas, so a gesture that reads deltas
    /// moves as far as one that reads the location. The location, window and time stay the newest drag's; a copy that
    /// does not keep them is not used.
    static func carrying(_ event: NSEvent, dx: CGFloat, dy: CGFloat) -> NSEvent {
        guard dx != 0 || dy != 0, let cg = event.cgEvent?.copy() else { return event }
        cg.setDoubleValueField(.mouseEventDeltaX, value: Double(event.deltaX + dx))
        cg.setDoubleValueField(.mouseEventDeltaY, value: Double(event.deltaY + dy))
        guard let copy = NSEvent(cgEvent: cg), copy.type == event.type, copy.windowNumber == event.windowNumber,
              copy.locationInWindow == event.locationInWindow else { return event }
        return copy
    }
}
