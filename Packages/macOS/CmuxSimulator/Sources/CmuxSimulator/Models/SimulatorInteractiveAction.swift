/// One bounded native input or diagnostic action executed inside the worker.
public enum SimulatorInteractiveAction: Codable, Equatable, Sendable {
    /// Delivers an ordered touch gesture.
    case gesture([SimulatorPointerEvent])
    /// Delivers an ordered touch gesture across an explicit total duration.
    case timedGesture(events: [SimulatorPointerEvent], durationMilliseconds: Int)
    /// Delivers touch down, up, or a balanced down/up pair.
    case touch(events: [SimulatorPointerEvent], holdMilliseconds: Int)
    /// Presses one or more USB HID keys sequentially.
    case keyPresses(
        usages: [UInt32],
        pressDurationMilliseconds: Int,
        interKeyDelayMilliseconds: Int
    )
    /// Presses one key while holding USB HID modifier usages.
    case keyChord(modifiers: [UInt32], key: UInt32)
    /// Types one validated US-keyboard text sequence.
    case typeText(SimulatorTextInputSequence)
    /// Presses and releases one hardware button.
    case hardwareButton(SimulatorHardwareButton)
    /// Presses and releases one hardware button with an explicit hold duration.
    case hardwareButtonHold(SimulatorHardwareButton, durationMilliseconds: Int)
    /// Rotates the simulated display.
    case rotate(SimulatorOrientation)
    /// Enables or disables one Core Animation diagnostic.
    case coreAnimation(SimulatorCADiagnostic, enabled: Bool)
    /// Sends a memory warning to the simulated device.
    case memoryWarning
}
