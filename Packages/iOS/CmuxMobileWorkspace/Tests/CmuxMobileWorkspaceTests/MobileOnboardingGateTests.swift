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

    /// Pairing state must not suppress the first-run explainer. Otherwise a user
    /// who auto-paired before seeing onboarding can delete every computer and get
    /// sent to onboarding later.
    @Test func showsOnboardingForNeverOnboardedButPaired() {
        #expect(MobileOnboardingGate.shouldShowOnboarding(
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
