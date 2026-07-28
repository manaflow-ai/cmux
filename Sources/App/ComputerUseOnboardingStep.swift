/// A screen in the Computer Use onboarding sequence.
enum ComputerUseOnboardingStep: Int, Hashable, Sendable {
    case overview
    case accessibility
    case screenRecording
    case complete

    static func nextMissingPermission(
        statusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> Self? {
        guard statusIsKnown else { return nil }
        if !accessibilityGranted { return .accessibility }
        if !screenRecordingGranted { return .screenRecording }
        return .complete
    }
}
