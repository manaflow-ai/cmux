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

/// One user-started trip to a System Settings permission pane.
///
/// Permission setup has its own generation, separate from background refreshes:
/// a refresh that replaced a started setup would leave Allow disabled forever.
struct ComputerUsePermissionSetupRequest: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var activeStep: ComputerUseOnboardingStep?

    var isInFlight: Bool { activeStep != nil }

    /// Starts `step`, or returns false while another setup is running.
    mutating func begin(_ step: ComputerUseOnboardingStep) -> Bool {
        guard activeStep == nil else { return false }
        activeStep = step
        generation &+= 1
        return true
    }

    /// Ends the setup started at `generation`; a stale finish changes nothing.
    mutating func finish(generation finishedGeneration: Int) {
        guard finishedGeneration == generation else { return }
        activeStep = nil
    }
}

/// How often onboarding may start the direct-capture check on its own.
///
/// The check disables Allow while it runs, up to a minute per helper profile.
/// A helper that is still restarting earns one automatic retry; after that only
/// the user's Allow click starts another, so status events cannot keep the
/// button disabled.
struct ComputerUseDirectCaptureAutoVerification: Equatable, Sendable {
    private(set) var attempted = false
    private var retryUsed = false

    var shouldVerifyAutomatically: Bool { !attempted }

    mutating func began() {
        attempted = true
    }

    mutating func recordUnavailable() {
        guard !retryUsed else { return }
        retryUsed = true
        attempted = false
    }

    mutating func reset() {
        attempted = false
        retryUsed = false
    }
}

/// The explanation beside the Screenshots row's Allow button.
enum ComputerUseScreenshotsCardDetail: Equatable, Sendable {
    case explainScreenshots
    case confirmInMacOS
    case waitingForMacOSAlert
    case retry

    static func resolve(
        statusIsKnown: Bool,
        screenRecordingGranted: Bool,
        directCaptureReady: Bool,
        verificationInFlight: Bool,
        verificationAttempted: Bool
    ) -> Self {
        guard statusIsKnown, screenRecordingGranted, !directCaptureReady else {
            return .explainScreenshots
        }
        if verificationInFlight { return .waitingForMacOSAlert }
        return verificationAttempted ? .retry : .confirmInMacOS
    }
}
