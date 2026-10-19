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
    /// Pointer travel, in window points, before a press becomes a window drag.
    private static let dragThreshold: CGFloat = 4
    private let nextEvent: @MainActor (NSWindow) -> SidebarEmptyAreaWindowDragTrackingEvent?

    /// Creates a controller with an injected event source.
    ///
    /// The default event source blocks in `.eventTracking` until the press
    /// resolves into either movement or a mouse-up.
    init(
        nextEvent: @escaping @MainActor (NSWindow) -> SidebarEmptyAreaWindowDragTrackingEvent? = { window in
            var eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                eventMask.insert(.mouseCancelled)
            }
            #endif
            guard let event = window.nextEvent(
                matching: eventMask,
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { return nil }

            #if compiler(>=6.2)
            if #available(macOS 26.0, *), event.type == .mouseCancelled {
                return .cancelled
            }
            #endif
            if event.type == .leftMouseUp {
                return .mouseUp(event)
            }
            return .dragged(location: event.locationInWindow)
        }
    ) {
        self.nextEvent = nextEvent
    }

    /// Consumes `event` as a window drag when the press turns into one.
    ///
    /// Returns `.dragged` when AppKit moved the window and `.cancelled` when
    /// the system ended the sequence without a mouse-up; callers consume both.
    /// Returns `.passThrough` for a press that never passed the configured drag
    /// threshold, having pushed the terminating mouse-up back onto the queue
    /// first — `NSTableView`'s own `mouseDown` tracking loop waits for that
    /// event, and swallowing it would hang the click.
    func perform(
        with event: NSEvent,
        in view: NSView
    ) -> SidebarEmptyAreaWindowDragOutcome {
        guard let window = view.window else { return .passThrough }
        guard !isWindowDragSuppressed(window: window) else { return .passThrough }

        let start = event.locationInWindow

        while let next = nextEvent(window) {
            switch next {
            case let .mouseUp(mouseUp):
                window.postEvent(mouseUp, atStart: true)
                return .passThrough
            case .cancelled:
                return .cancelled
            case let .dragged(location):
                let distance = hypot(location.x - start.x, location.y - start.y)
                guard distance >= Self.dragThreshold else { continue }

                withTemporaryWindowMovableEnabled(window: window) {
                    // AppKit requires the original mouse-down event; the
                    // tracked location only decides when to hand off.
                    window.performDrag(with: event)
                }
                return .dragged
            }
        }

        // A source that ends without mouse-up cannot safely fall through to
        // AppKit's tracking loop, which would wait for an event that may never
        // arrive. Treat it as a consumed cancellation.
        return .cancelled
    }
}
