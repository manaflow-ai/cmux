/// One bounded native input or diagnostic action executed inside the worker.
public enum SimulatorInteractiveAction: Codable, Equatable, Sendable {
    /// Delivers an ordered touch gesture.
    case gesture([SimulatorPointerEvent])
    /// Presses and releases one hardware button.
    case hardwareButton(SimulatorHardwareButton)
    /// Rotates the simulated display.
    case rotate(SimulatorOrientation)
    /// Enables or disables one Core Animation diagnostic.
    case coreAnimation(SimulatorCADiagnostic, enabled: Bool)
    /// Sends a memory warning to the simulated device.
    case memoryWarning
}
