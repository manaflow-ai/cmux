/// A screen in the Computer Use onboarding sequence.
enum ComputerUseOnboardingStep: Int, Sendable {
    case overview
    case accessibility
    case screenRecording
    case done

    var continuation: (nextStep: Self, settingsStepToOpen: Self?) {
        switch self {
        case .overview:
            (.accessibility, nil)
        case .accessibility:
            (.screenRecording, .screenRecording)
        case .screenRecording:
            (.done, nil)
        case .done:
            (.done, nil)
        }
    }

    var previous: Self {
        switch self {
        case .overview, .accessibility:
            .overview
        case .screenRecording:
            .accessibility
        case .done:
            .screenRecording
        }
    }
}
