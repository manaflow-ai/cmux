public import AppKit
import CmuxNextDesignTokens
import CmuxNextWakeups

/// A window's live-resize drags as input of its next display frame (FRAME OWNER REFACTOR S7,
/// `motion.frameOwner.liveResize`). On macOS 26 and 27 AppKit resizes a window from each drag event the window gets
/// (`-[NSWindow sendEvent:]` -> its resize gesture -> `setFrame(_:display:)`), and each `setFrame` lays the whole view
/// tree out in that event's turn: with drags queued behind a long turn, the window resized and laid out once per event,
/// back to back, and its frame ticks came 44-62 ms apart (px-window-resize-4, 52-67 dropped refreshes per film).
///
/// Now a drag that comes while the window resizes live is kept, the newest replacing the one before, and the window's
/// frame tick gives it to AppKit as an input client (it ticks before the springs and probes): one window frame, one
/// layout pass and one commit per display frame, in the tick's own transaction. Chrome aligns input to the begin-frame
/// the same way. Any other event of the window (the release, a key, a modifier change) gives the waiting drag to
/// AppKit first, in its own turn, so the release lands where the pointer let go and nothing reorders.
///
/// The switch is read at a resize's first held drag and kept until the next press or release, so one resize never
/// mixes the two paths. A drag outside a live resize (a text selection, a tab drag) goes on in its own turn.
@MainActor
public final class LiveResizeDragInput {
    /// Frame ticks the client keeps after the last drag, so a slow drag does not make the display link again for each
    /// event (about 67 ms at 120 Hz, as a divider drag's `panTickTail`).
    static let tickTail = 8

    private weak var window: NSWindow?
    /// Gives an event to AppKit (the window's `super.sendEvent`).
    private let deliver: @MainActor (NSEvent) -> Void
    /// The newest drag that waits for the frame tick, and the pointer travel of the drags it replaced.
    private var waiting: (event: NSEvent, dx: CGFloat, dy: CGFloat)?
    /// The switch for the resize in progress, read at its first held drag; nil between resizes.
    private var latched: Bool?
    private var ticksLeft = 0
    private lazy var client = FrameClient(owner: "LiveResize.drag", isAnimation: false, input: true, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    /// Drags given to AppKit from a frame tick and drags a newer one replaced, cumulative (diagnostics and tests).
    public private(set) var tickDeliveries = 0, replaced = 0

    /// `deliver` gives an event to AppKit for `window` (its `super.sendEvent`).
    public init(window: NSWindow, deliver: @escaping @MainActor (NSEvent) -> Void) {
        self.window = window
        self.deliver = deliver
    }

    /// Whether `event` (sent to this input's window) waits for the frame tick. False: the caller sends it now; a
    /// waiting drag has gone to AppKit first.
    public func takes(_ event: NSEvent) -> Bool { // perf-hot: 0.5ms drag-frame
        guard event.type == .leftMouseDragged, let window, Motion.isLiveResizing(window) else {
            flush()
            switch event.type {
            case .leftMouseDown, .leftMouseUp: latched = nil
            default: break
            }
            return false
        }
        let on = latched ?? MotionTunables.frameOwnerLiveResize.value
        latched = on
        guard on else { return false }
        if let waiting {
            replaced += 1
            self.waiting = (event, waiting.dx + waiting.event.deltaX, waiting.dy + waiting.event.deltaY)
        } else {
            waiting = (event, 0, 0)
        }
        ticksLeft = Self.tickTail
        client.activate()
        return true
    }

    /// The window closes: a waiting drag goes with it, and no more frames.
    public func windowWillClose() {
        waiting = nil
        latched = nil
        client.deactivate()
    }

    /// The window's frame tick: the waiting drag goes to AppKit, which resizes the window and lays it out in this tick.
    private func tick() -> Bool { // perf-hot: 4ms motion-frame
        if waiting != nil {
            tickDeliveries += 1
            flush()
            ticksLeft = Self.tickTail
            return true
        }
        ticksLeft -= 1
        return ticksLeft > 0
    }

    private func flush() {
        guard let waiting else { return }
        self.waiting = nil
        deliver(Self.carrying(waiting.event, dx: waiting.dx, dy: waiting.dy))
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
