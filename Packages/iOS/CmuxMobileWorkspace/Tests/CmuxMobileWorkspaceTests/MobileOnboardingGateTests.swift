import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileOnboardingGateTests {
    /// The genuine first run: never onboarded and no paired Mac. Onboarding shows.
    @Test func showsOnboardingForNeverOnboardedNeverPaired() {
        #expect(MobileOnboardingGate.shouldShowOnboarding(
            hasSeenOnboarding: false,
            hasKnownPairedMac: false
        ))
    }

    /// A returning, paired-but-offline user (reachable after a failed stored-Mac
    /// reconnect) must not be interrupted by onboarding, even if the seen flag is
    /// still `false` because they updated from a build that predates the flag.
    @Test func skipsOnboardingForNeverOnboardedButPaired() {
        #expect(!MobileOnboardingGate.shouldShowOnboarding(
            hasSeenOnboarding: false,
            hasKnownPairedMac: true
        ))
    }

    /// Already onboarded and not yet paired: onboarding was seen, fall through to
    /// the add-device / pairing flow without showing it again.
    @Test func skipsOnboardingForOnboardedNeverPaired() {
        #expect(!MobileOnboardingGate.shouldShowOnboarding(
            hasSeenOnboarding: true,
            hasKnownPairedMac: false
        ))
    }

    /// Onboarded and paired: never show onboarding.
    @Test func skipsOnboardingForOnboardedAndPaired() {
        #expect(!MobileOnboardingGate.shouldShowOnboarding(
            hasSeenOnboarding: true,
            hasKnownPairedMac: true
        ))
    }
}
