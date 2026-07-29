public import CmuxMobileShellModel

/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// Onboarding demonstrates the product before authentication, then hands into
/// sign-in and same-account computer discovery at the connection milestone. The
/// single decision uses only durable onboarding progress. Live connection state
/// never suppresses an unfinished flow, so cancelling QR fallback returns to the
/// connection step.
public extension MobileOnboardingProgress {
    /// Whether the first-run onboarding should be presented.
    ///
    /// - Returns: `true` until onboarding is explicitly completed.
    var shouldShowOnboarding: Bool {
        self != .complete
    }
}
