/// The durable milestone reached by the iOS onboarding flow.
///
/// Only milestones that matter across launches are persisted. Each case names
/// the step the person should resume at: the welcome pitch, connecting a Mac
/// (which sign-in precedes when needed), or the push-notification offer.
public enum MobileOnboardingProgress: String, Equatable, Sendable {
    /// The welcome pitch has not been completed yet.
    case welcome

    /// The pitch is done; the next step is sign-in and connecting a computer.
    case connect

    /// Connection setup was finished or skipped; the push offer remains.
    case push

    /// Onboarding finished. Individual steps may have been skipped.
    case complete
}
