public import CmuxNextHomeModel

/// What a click on Meet Chief's card asks for (``HomeNativeTranscriptView/onChiefOnboarding``); the host runs it
/// on ``ChiefOnboarding`` or the app.
public enum HomeChiefOnboardingAction: Sendable, Equatable {
    /// Continue, or Start chatting on the last step.
    case next
    /// Back to the step before.
    case back
    /// Skip: it ends for good.
    case skip
    /// The person picked a permission mode.
    case choose(ChiefPermissionMode)
    /// The person picked a density.
    case density(ChiefOnboardingDensity)
    /// The text gets one point smaller (-1) or larger (1).
    case textSize(Double)
    /// Open Settings at what the step changes: Chief's permission mode, or the density.
    case openSettings(ChiefOnboardingStep)
}
