/// One step of trusted mouse input, named as the DevTools protocol names it.
public enum BrowserAutomationMouseAction: String, Sendable, Equatable {
    /// The pointer moves.
    case moved = "mouseMoved"
    /// A button goes down.
    case pressed = "mousePressed"
    /// A button comes up.
    case released = "mouseReleased"
    /// The wheel scrolls.
    case wheel = "mouseWheel"
}

/// A mouse button, named as the DevTools protocol names it.
public enum BrowserAutomationMouseButton: String, Sendable, Equatable {
    /// No button (moves and wheel events).
    case noButton = "none"
    /// The primary button.
    case left
    /// The middle button.
    case middle
    /// The secondary button.
    case right
}
