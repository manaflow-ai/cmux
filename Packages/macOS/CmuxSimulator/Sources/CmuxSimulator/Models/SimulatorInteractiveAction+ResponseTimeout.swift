extension SimulatorInteractiveAction {
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
