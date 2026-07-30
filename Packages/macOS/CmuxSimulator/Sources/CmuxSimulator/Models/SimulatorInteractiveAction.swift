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

    /// Deadline that covers the action's declared pacing plus worker overhead.
    public var responseTimeout: Duration {
        let executionMilliseconds: Double
        switch self {
        case let .timedGesture(_, durationMilliseconds),
             let .touch(_, durationMilliseconds):
            executionMilliseconds = Double(max(0, durationMilliseconds))
        case let .keyPresses(
            usages,
            pressDurationMilliseconds,
            interKeyDelayMilliseconds
        ):
            let keyCount = Double(usages.count)
            executionMilliseconds =
                keyCount * Double(max(0, pressDurationMilliseconds))
                + Double(max(0, usages.count - 1))
                    * Double(max(0, interKeyDelayMilliseconds))
        case let .typeText(sequence):
            executionMilliseconds = sequence.completionTimeoutSeconds * 1_000
        case let .hardwareButtonHold(_, durationMilliseconds):
            executionMilliseconds = Double(max(0, durationMilliseconds))
        case .gesture, .keyChord, .hardwareButton, .rotate, .coreAnimation,
             .memoryWarning:
            executionMilliseconds = 0
        }
        let boundedMilliseconds = min(
            125_000,
            max(30_000, executionMilliseconds + 5_000)
        )
        return .milliseconds(Int64(boundedMilliseconds.rounded(.up)))
    }
}
