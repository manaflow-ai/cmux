/// A semantic action supported by one runtime UI element.
public enum SimulatorUIAutomationActionName: String, Codable, Equatable, Sendable {
    /// Activates the element with a short touch.
    case tap
    /// Focuses the element and enters text with keyboard HID events.
    case typeText
    /// Holds a touch on the element.
    case longPress
    /// Sends explicit touch-down and touch-up phases.
    case touch
    /// Performs a directional gesture inside the element's visible bounds.
    case swipeWithin
}
