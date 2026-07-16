/// The host input devices captured by the isolated Simulator worker.
public enum SimulatorHIDCaptureMode: String, Codable, CaseIterable, Sendable {
  case none
  case keyboard
  case pointerAndKeyboard
}
