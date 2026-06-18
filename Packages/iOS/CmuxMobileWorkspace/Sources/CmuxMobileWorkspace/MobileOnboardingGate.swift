/// Pure gating policy for the first-run onboarding screen in the mobile root scene.
///
/// Onboarding is a one-time explainer (what cmux is, what it needs, how to pair)
/// shown post-authentication and *in front of* the never-paired add-device state.
/// The single decision — show it or fall through to pairing — combines the
/// persisted "seen" flag with whether this install has a known paired Mac, so the
/// gate is a pure function the root scene can branch on and tests can cover
/// without a store. It mirrors ``MobileRootAuthGate``.
public struct MobileOnboardingGate {
    private init() {}

    /// Whether the first-run onboarding should be presented.
    ///
    /// Onboarding shows only for a genuine first run: the user has not seen it
    /// *and* this install has never paired a Mac. The paired check excludes a
    /// returning, paired-but-offline user — who can reach this branch after a
    /// failed stored-Mac reconnect — from being interrupted by onboarding even
    /// when their seen flag is still `false` (an older install updating into the
    /// build that introduced the flag).
    ///
    /// The caller places this branch *after* the stored-Mac reconnect-determining
    /// branch, so ``hasKnownPairedMac`` has resolved (the determining spinner
    /// absorbs the resolution window) and is authoritative here.
    ///
    /// - Parameters:
    ///   - hasSeenOnboarding: Whether onboarding has already been shown (or
    ///     bypassed for UI tests / dogfood) on this install.
    ///   - hasKnownPairedMac: Whether this install has a known paired Mac.
    /// - Returns: `true` only when onboarding has not been seen and no paired Mac
    ///   is known.
    public static func shouldShowOnboarding(
        hasSeenOnboarding: Bool,
        hasKnownPairedMac: Bool
    ) -> Bool {
        !hasSeenOnboarding && !hasKnownPairedMac
    }
}
