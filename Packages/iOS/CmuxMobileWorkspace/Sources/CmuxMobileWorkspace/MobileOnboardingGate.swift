public import CmuxMobileShellModel

/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// The welcome pitch shows before authentication. Every later step (connecting
/// a computer, the push offer) assumes an account, so when progress has moved
/// past `welcome` and the person is signed out, the root shows sign-in instead;
/// onboarding resumes at the persisted milestone once authentication completes.
/// Live connection state never suppresses an unfinished flow, so cancelling QR
/// fallback returns to the connection step.
public extension MobileOnboardingProgress {
    /// Whether the first-run onboarding should be presented.
    ///
    /// - Parameter isAuthenticated: Whether the person currently has a usable
    ///   account session (Stack or attach-ticket).
    /// - Returns: `true` until onboarding is explicitly completed, except while
    ///   a post-welcome milestone is waiting on sign-in.
    func shouldShowOnboarding(isAuthenticated: Bool) -> Bool {
        switch self {
        case .welcome:
            true
        case .connect, .push:
            isAuthenticated
        case .complete:
            false
        }
    }
}
