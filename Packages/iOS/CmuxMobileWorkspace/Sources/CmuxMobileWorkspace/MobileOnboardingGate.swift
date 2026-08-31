public import CmuxMobileShellModel

/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// Onboarding presents only to a signed-in account: a signed-out launch goes
/// straight to sign-in, and the flow presents (or resumes) once authentication
/// succeeds, handing into same-account computer discovery at the connection
/// milestone. Beyond authentication the decision uses only durable onboarding
/// progress. Live connection state never suppresses an unfinished flow, so
/// cancelling QR fallback returns to the connection step.
public extension MobileOnboardingProgress {
    /// Whether the first-run onboarding should be presented.
    ///
    /// - Parameter isAuthenticated: Whether an account is signed in. Without
    ///   one there is nothing to onboard into, so sign-in owns the screen.
    /// - Returns: `true` for a signed-in account until onboarding is
    ///   explicitly completed.
    func shouldShowOnboarding(isAuthenticated: Bool) -> Bool {
        isAuthenticated && self != .complete
    }
}
