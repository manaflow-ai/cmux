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

/// The only automatic transitions allowed after a permission refresh.
///
/// The first grant returns to the main window so Screenshots requires its own
/// explicit Allow action. The second grant verifies Tahoe's separate direct
/// capture consent before setup can complete.
enum ComputerUseOnboardingAdvance: Equatable, Sendable {
    case none
    case requestSecondAllow
    case verifyScreenCapture
    case complete

    static func resolve(
        activeStep: ComputerUseOnboardingStep,
        statusIsKnown: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        directCaptureReady: Bool
    ) -> Self {
        guard statusIsKnown, accessibilityGranted else { return .none }
        if activeStep == .accessibility, !screenRecordingGranted {
            return .requestSecondAllow
        }
        guard screenRecordingGranted else { return .none }
        return directCaptureReady ? .complete : .verifyScreenCapture
    }
}

/// The operation behind an Allow button in the expanded onboarding window.
///
/// Once ordinary Screen Recording is granted, the same Screenshots row retries
/// Tahoe's direct-capture consent instead of reopening a permission pane that
/// can no longer advance setup.
enum ComputerUseOnboardingAllowAction: Equatable, Sendable {
    case openSystemSettings
    case verifyScreenCapture
    case none

    static func resolve(
        permissionStep: ComputerUseOnboardingStep,
        statusIsKnown: Bool,
        screenRecordingGranted: Bool,
        directCaptureReady: Bool
    ) -> Self {
        guard permissionStep == .screenRecording else {
            return permissionStep == .accessibility ? .openSystemSettings : .none
        }
        guard statusIsKnown, screenRecordingGranted else {
            return .openSystemSettings
        }
        return directCaptureReady ? .none : .verifyScreenCapture
    }
}
