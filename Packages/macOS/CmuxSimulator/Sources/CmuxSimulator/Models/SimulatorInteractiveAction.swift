/// One bounded native input or diagnostic action executed inside the worker.
public enum SimulatorInteractiveAction: Codable, Equatable, Sendable {
    case gesture([SimulatorPointerEvent])
    case hardwareButton(SimulatorHardwareButton)
    case rotate(SimulatorOrientation)
    case coreAnimation(SimulatorCADiagnostic, enabled: Bool)
    case memoryWarning
}
