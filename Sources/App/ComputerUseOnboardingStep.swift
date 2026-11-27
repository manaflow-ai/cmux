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
        if screenRecordingGranted, directCaptureReady {
            return .complete
        }
        if activeStep == .accessibility {
            return .requestSecondAllow
        }
        guard activeStep == .screenRecording, screenRecordingGranted else {
            return .none
        }
        return .verifyScreenCapture
    }
}

/// What the compact permission companion should instruct beside System Settings.
///
/// While the direct-capture probe is in flight, macOS shows its own consent
/// alert (worded as the helper "attempting to bypass the system private window
/// picker"). The companion must explain that alert instead of still telling the
/// user to drag the helper into a permission list it has already left.
enum ComputerUsePermissionCompanionMessage: Equatable, Sendable {
    case dragIntoAccessibility
    case dragIntoScreenshots
    case confirmScreenCapture

    static func resolve(
        permissionStep: ComputerUseOnboardingStep,
        screenCaptureConsentPending: Bool
    ) -> Self {
        guard !screenCaptureConsentPending else { return .confirmScreenCapture }
        return permissionStep == .accessibility
            ? .dragIntoAccessibility
            : .dragIntoScreenshots
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
