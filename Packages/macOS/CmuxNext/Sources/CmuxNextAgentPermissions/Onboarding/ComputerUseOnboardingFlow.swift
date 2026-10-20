/// Computer use onboarding as a function of what is true now, never a
/// stored step index: a grant removed later sends the flow back to that
/// grant's step by itself, and a grant given elsewhere skips its step.
///
/// ```swift
/// var flow = ComputerUseOnboardingFlow(helperAvailable: true)
/// flow.introSeen = true
/// flow.step // .accessibility until the grant lands
/// ```
public nonisolated struct ComputerUseOnboardingFlow: Sendable, Equatable {
    /// A Developer ID signed Computer Use helper exists in this build.
    public var helperAvailable: Bool
    /// The person pressed Set up on the intro.
    public var introSeen: Bool
    /// The helper holds Accessibility.
    public var accessibility: Bool
    /// The helper holds Screen Recording.
    public var screenRecording: Bool
    /// The test click worked with the current grants.
    public var trialPassed: Bool
    /// The last test click failed (the step shows Retry and which grant is missing).
    public var trialFailed: Bool

    public init(helperAvailable: Bool, introSeen: Bool = false, accessibility: Bool = false, screenRecording: Bool = false,
                trialPassed: Bool = false, trialFailed: Bool = false) {
        self.helperAvailable = helperAvailable
        self.introSeen = introSeen
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.trialPassed = trialPassed
        self.trialFailed = trialFailed
    }

    /// The step to show now.
    public var step: ComputerUseOnboardingStep {
        if notImplemented { return .intro }
        guard helperAvailable else { return .unavailable }
        guard introSeen else { return .intro }
        guard accessibility else { return .accessibility }
        guard screenRecording else { return .screenRecording }
        guard trialPassed else { return .tryIt }
        return .howToStop
    }

    /// The step's place in ``ComputerUseOnboardingStep/counted`` (0-based), nil while unavailable.
    public var progress: Int? { ComputerUseOnboardingStep.counted.firstIndex(of: step) }

    /// Applies the helper's grants. A grant that went away also clears the
    /// test result, so the person retries with the grants they have now.
    public mutating func apply(accessibility: Bool, screenRecording: Bool) {
        if (self.accessibility && !accessibility) || (self.screenRecording && !screenRecording) {
            trialPassed = false
            trialFailed = false
        }
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    /// Records the test click's result.
    public mutating func recordTrial(passed: Bool) {
        trialPassed = passed
        trialFailed = !passed
    }

    /// The grant a failed test click points at: the first one still off, else nil (retry).
    public var missingGrant: PermissionKind? {
        if !accessibility { return .accessibility }
        if !screenRecording { return .screenRecording }
        return nil
    }
}

/// Red commit: the behavior lands in the next commit.
private nonisolated var notImplemented: Bool { true }
