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
/// Chrome aligns continuous input to the begin-frame and pays up to a refresh of latency for it; here the drags of a
/// frame that has room do not wait (R-HARNESS 3d, films ab-s7-sw-63b290e: when every drag waited for the tick, 64 and
/// 71 frames showed the whole window one refresh late, against 12 and 14 with the switch off). Any other event of the
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
    /// A drag was applied in the display frame that runs now (since the last frame tick): a drag that comes now waits
    /// for the next tick. A tick starts a display frame; it applies the waiting drag, if any.
    private var appliedThisFrame = false
    /// `setFrame`s of the resize running now (``applyingFrame(_:)``; one unless AppKit sets the frame again inside it).
    private var applyingDepth = 0
    private var ticksLeft = 0
    private lazy var client = FrameClient(owner: "LiveResize.drag", isAnimation: false, input: true, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    /// A `setFrame` of the live resize runs now: what it changes is not final until it returns (`frameApplied` then).
    public var isApplyingFrame: Bool { applyingDepth > 0 }

    /// This live resize applies at most one drag per display frame: `motion.frameOwner.liveResize` read at its first
    /// drag and kept until the release. What else S7 changes in a live resize (``LiveResizePageUpdates``, ``FollowedViews``) follows it.
    public var isFramed: Bool { latched == true }

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
            case .leftMouseDown, .leftMouseUp: latched = nil
            default: break
            }
            return false
        }
        let on = latched ?? MotionTunables.frameOwnerLiveResize.value
        latched = on
        guard on else {
            noteApplying(event, atTick: false)
            return false
        }
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

    /// A `setFrame` of the window in its live resize (`apply`): when this resize's drags wait for the frame tick, the
    /// views another window follows post their frame notices once, after it, with the final geometry (``FollowedViews``);
    /// then `frameApplied` runs, once, after the outermost `setFrame` returns (``isApplyingFrame`` is false by then).
    public func applyingFrame(_ apply: () -> Void) {
        applyingDepth += 1
        defer {
            applyingDepth -= 1
            if applyingDepth == 0 { frameApplied() }
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // The outermost `setFrame` only: one sample per applied drag.
        let applied = applyingDepth == 1 ? nextApplied : nil
        if applyingDepth == 1 { nextApplied = nil }
        let frame = applyingDepth == 1 ? window.flatMap { probe.frameWillApply(in: $0, eventTime: applied?.eventTime, atTick: applied?.atTick == true) } : nil
        defer { if let frame { probe.frameDidApply(frame) } }
        #endif
        guard isFramed, let window else { return apply() }
        FollowedViews.of(window).holdingFrameNotices(apply)
    }

    /// The window closes: a waiting drag goes with it, and no more frames.
    public func windowWillClose() {
        waiting = nil
        latched = nil
        appliedThisFrame = false
        client.deactivate()
    }

    /// The window's frame tick starts a display frame: the waiting drag goes to AppKit, which resizes the window and lays
    /// it out in this tick, and that is the frame's drag. With none waiting, the frame's first drag goes in its own turn.
    private func tick() -> Bool { // perf-hot: 4ms motion-frame
        appliedThisFrame = waiting != nil
        if waiting != nil {
            tickDeliveries += 1
            flush(atTick: true)
            ticksLeft = Self.tickTail
            return true
        }
        ticksLeft -= 1
        return ticksLeft > 0
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
