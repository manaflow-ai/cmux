/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// Onboarding is a one-time explainer (what cmux is, what it needs, how to pair)
/// shown post-authentication and *in front of* the never-paired add-device state.
/// The single decision — show it or fall through to pairing — uses only the
/// persisted "seen" flag, so pairing state cannot defer onboarding until a later
/// delete-all flow. It mirrors ``MobileRootAuthGate``.
public struct MobileOnboardingGate {
    private init() {}

    /// Whether the first-run onboarding should be presented.
    ///
    /// Onboarding shows when the user has not seen it yet, regardless of whether
    /// the app has already auto-paired a Mac.
    ///
    /// - Parameters:
    ///   - hasSeenOnboarding: Whether onboarding has already been shown (or
    ///     bypassed for UI tests / dogfood) on this install.
    /// - Returns: `true` only when onboarding has not been seen.
    public static func shouldShowOnboarding(
        hasSeenOnboarding: Bool
    ) -> Bool {
        !hasSeenOnboarding
    }
}
