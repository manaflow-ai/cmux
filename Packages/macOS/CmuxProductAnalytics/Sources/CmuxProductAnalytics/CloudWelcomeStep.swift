/// The welcome card's primary action, decided by sign-in and plan.
public enum CloudWelcomeStep: String, Sendable, CaseIterable {
    /// Free or signed out: Upgrade opens pricing.
    case upgrade
    /// Paid plan or a shared team: Enable turns Cloud on.
    case enable
    /// Sign in first.
    case signIn = "sign_in"
    /// The plan is not known yet: open the Cloud sidebar, which decides.
    case openCloud = "open_cloud"
}
