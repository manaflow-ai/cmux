/// The durable activation milestone reached by the iOS onboarding flow.
///
/// Only milestones that matter across launches are persisted. The two product
/// demonstration scenes are intentionally grouped into ``welcome`` so people
/// can move through them freely, while ``connect`` resumes at the one remaining
/// prerequisite after they have chosen to set up cmux.
public enum MobileOnboardingProgress: String, Equatable, Sendable {
    /// The product demonstration has not been completed yet.
    case welcome

    /// The value tour is complete and the next step is connecting a computer.
    case connect

    /// Onboarding was skipped or a computer connection completed successfully.
    case complete
}
