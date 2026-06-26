public import AppKit

/// Decides whether the titlebar drag handle should resolve an *active* hit
/// capture for an incoming event, versus treating the event as passive.
///
/// A pure value type. The app target builds it from the live event and window
/// identities and asks `shouldResolveActiveHitCapture`.
public struct WindowDragHandleActiveHitResolution {
    /// The type of the event currently being resolved, if any.
    public let eventType: NSEvent.EventType?
    /// The window the event targets, if any.
    public let eventWindow: NSWindow?
    /// The window hosting the drag handle, if attached.
    public let dragHandleWindow: NSWindow?

    /// Creates an active-hit-capture resolution from the event and window identities.
    public init(
        eventType: NSEvent.EventType?,
        eventWindow: NSWindow?,
        dragHandleWindow: NSWindow?
    ) {
        self.eventType = eventType
        self.eventWindow = eventWindow
        self.dragHandleWindow = dragHandleWindow
    }

    /// Whether active hit resolution should run for this event.
    ///
    /// Pure value predicate, faithful lift of the app-side
    /// `windowDragHandleShouldResolveActiveHitCapture` free function.
    public var shouldResolveActiveHitCapture: Bool {
        // We only need active hit resolution for titlebar mouse-down handling.
        // During launch, NSApp.currentEvent can transiently point at a stale
        // leftMouseDown from outside this window (for example Finder/Dock
        // activation). Treat those as passive events so we never walk SwiftUI/
        // AppKit hierarchy while initial layout is mutating it.
        guard eventType == .leftMouseDown else {
            return false
        }
        guard let dragHandleWindow else {
            // Test-only views may not be attached to a window.
            return true
        }
        guard let eventWindow else {
            return false
        }
        return eventWindow === dragHandleWindow
    }
}
