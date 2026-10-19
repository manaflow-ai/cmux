public import CmuxMobileShellModel

/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// Onboarding presents only after the account session is settled: a signed-out
/// or restoring launch goes straight to sign-in, and the flow presents (or
/// resumes) once authentication succeeds. Beyond authentication the decision
/// uses only durable onboarding progress. Live connection state never
/// suppresses an unfinished flow, so cancelling QR fallback returns to the
/// connection step.
public extension MobileOnboardingProgress {
    /// Whether the first-run onboarding should be presented.
    ///
    /// - Parameters:
    ///   - isAuthenticated: Whether an account is currently authenticated.
    ///   - isRestoringSession: Whether that session is still being validated at
    ///     launch. A primed cached identity is not a settled session, so
    ///     sign-in owns the screen until restore completes.
    /// - Returns: `true` for a signed-in account until onboarding is
    ///   explicitly completed.
    func shouldShowOnboarding(
        isAuthenticated: Bool,
        isRestoringSession: Bool
    ) -> Bool {
        isAuthenticated && !isRestoringSession && self != .complete
    }
}
