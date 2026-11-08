public import AppKit

/// Delivers a press, its drags and its release to the window that owns the press's place now, when the window server
/// gave the press to another one (ZOOM VARIANTS 8, fork only).
///
/// While a film zoom plays, the divider catcher panels stay where the dividers were before the key (they follow at the
/// film's end or its deadline: `LayoutRootView.catchersWaitForLanding`). The window server hit-tests the windows as they
/// are, so a press there went to a catcher that no divider owns any more (zoom in: the press missed the zoomed page), or
/// to a page window over a new divider that has no catcher yet (zoom out: the page took the divider press). The app asks
/// the press's top window (its overlay layer, `DividerMouseCatchers.pressTarget`) for the press's window at the press
/// (``deliver(_:target:)``); the catchers move first. The window server keeps sending the drags and the release to the window that got the press, so they follow the
/// press to the same window until the release.
@MainActor
public final class DividerPressRetarget {
    /// The window number the window server sends the press's events to, and the window that takes them instead.
    private var held: (source: Int, target: NSWindow?)?

    /// Makes the router.
    public init() {}

    /// Whether `event` went to another window than its own: `target` names the press's window (nil: its own window).
    ///
    /// - Parameter event: An event `NSApplication.sendEvent(_:)` got.
    /// - Parameter target: Given the press and the top window over its window (the window whose child it is, or itself),
    ///   the window the press belongs to now, or nil when the window server's own window is right.
    /// - Returns: Whether the event was delivered here; the app then does not send it on.
    public func deliver(_ event: NSEvent, target: (NSEvent, NSWindow) -> NSWindow?) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            held = nil
            var top = event.window
            while let parent = top?.parent { top = parent }
            guard let top, let window = target(event, top), window.windowNumber != event.windowNumber else { return false }
            held = (event.windowNumber, window)
            return send(event, to: window)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let held, held.source == event.windowNumber, let window = held.target else { return false }
            return send(event, to: window)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let held, held.source == event.windowNumber, let window = held.target else { return false }
            self.held = nil
            return send(event, to: window)
        default:
            return false
        }
    }

    /// The same event at the same screen point, for `window`.
    private func send(_ event: NSEvent, to window: NSWindow) -> Bool {
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        guard let moved = NSEvent.mouseEvent(
            with: event.type, location: window.convertPoint(fromScreen: point), modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: event.pressure
        ) else { return false }
        window.sendEvent(moved)
        return true
    }
}
