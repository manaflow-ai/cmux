public import AppKit

extension NSEvent {
    /// Where the event happened, in screen points (AppKit's global coordinates, origin at the
    /// primary display's bottom left), read from the event, not from the live cursor: a handler
    /// reads its event, as Chromium's `ui/events/cocoa/events_mac.mm` takes an event's location
    /// from the native event.
    ///
    /// An event with no window already carries screen points. For one with a window, the window
    /// server's own location comes first: it holds while the window moves under the pointer (a
    /// window or panel dragged by its own handler, whose `locationInWindow` is relative to the
    /// frame the window server knew when it made the event).
    public var screenLocation: NSPoint {
        guard let window else { return locationInWindow }
        return cgEvent?.unflippedLocation ?? window.convertPoint(toScreen: locationInWindow)
    }
}
