/// The host input devices captured by the isolated Simulator worker.
public enum SimulatorHIDCaptureMode: String, Codable, CaseIterable, Sendable {
    /// The worker is not capturing host input.
    case none
    /// The worker is capturing keyboard input.
    case keyboard
    /// The worker is capturing pointer and keyboard input.
    case pointerAndKeyboard
}
