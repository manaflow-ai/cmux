/// A phase in a USB HID keyboard event.
public enum SimulatorKeyPhase: String, Codable, Sendable {
    /// The key was pressed.
    case down
    /// The key was released.
    case up
}
