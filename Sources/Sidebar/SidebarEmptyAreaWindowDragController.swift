import AppKit

/// Coordinates window dragging from empty sidebar space.
///
/// Tracking runs synchronously from `mouseDown` with `nextEvent(matching:)`,
/// the same shape as ``SidebarDividerTrackingView``, rather than through an
/// `NSGestureRecognizer`. `NSWindow.performDrag(with:)` runs its own modal
/// tracking loop and consumes the terminating mouse-up, so a recognizer that
/// calls it never receives the event that would drive it back to `.possible`:
/// it stays parked in a terminal state, `reset()` never runs, and it silently
/// stops recognizing for the rest of the window's life.
@MainActor
struct SidebarEmptyAreaWindowDragController {
    private let dragThreshold: CGFloat
    private let nextEvent: (NSWindow) -> NSEvent?

    /// Creates a controller with its pointer threshold and event source.
    ///
    /// The default event source blocks in `.eventTracking` until the press
    /// resolves into either movement or a mouse-up.
    init(
        dragThreshold: CGFloat = 4,
        nextEvent: @escaping (NSWindow) -> NSEvent? = { window in
            window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
        }
    ) {
        self.dragThreshold = dragThreshold
        self.nextEvent = nextEvent
    }

    /// Consumes `event` as a window drag when the press turns into one.
    ///
    /// Returns `true` when the window was dragged and the caller must not run
    /// its normal `mouseDown` handling. Returns `false` for a press that never
    /// passed the configured drag threshold, having pushed the terminating
    /// mouse-up back onto the queue first — `NSTableView`'s own `mouseDown`
    /// tracking loop waits for that event, and swallowing it would hang the
    /// click.
    func perform(
        with event: NSEvent,
        in view: NSView
    ) -> Bool {
        guard let window = view.window else { return false }
        guard !isWindowDragSuppressed(window: window) else { return false }

        let start = event.locationInWindow

        while let next = nextEvent(window) {
            if next.type == .leftMouseUp {
                window.postEvent(next, atStart: true)
                return false
            }

            let location = next.locationInWindow
            let distance = hypot(location.x - start.x, location.y - start.y)
            guard distance >= dragThreshold else { continue }

            withTemporaryWindowMovableEnabled(window: window) {
                window.performDrag(with: event)
            }
            return true
        }

        return false
    }
}
