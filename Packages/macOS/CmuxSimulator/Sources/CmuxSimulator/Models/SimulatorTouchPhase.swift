/// A phase in a simulated touch sequence.
public enum SimulatorTouchPhase: String, Codable, Sendable {
    /// A finger contacted the display.
    case began
    /// A contacting finger moved.
    case moved
    /// A finger left the display.
    case ended
    /// The host cancelled the gesture and requires input cleanup.
    case cancelled
}
