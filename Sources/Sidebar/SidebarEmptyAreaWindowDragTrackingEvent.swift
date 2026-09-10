import AppKit

/// Event-source value consumed by the synchronous empty-area tracking loop.
enum SidebarEmptyAreaWindowDragTrackingEvent {
    /// Pointer movement that may cross the drag threshold.
    case dragged(location: NSPoint)
    /// The terminating event that normal click handling still needs.
    case mouseUp(NSEvent)
    /// A system cancellation that terminates the sequence without mouse-up.
    case cancelled
}
