#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingKeepAwakeOfferTests {
    @Test func knownStateOnLiveCapableConnectionMakesTheOffer() {
        #expect(OnboardingKeepAwakeOffer.make(
            isConnected: true,
            isSupported: true,
            isEnabled: false,
            isBusy: false
        ) == OnboardingKeepAwakeOffer(isEnabled: false, isBusy: false))
    }

    @Test func alreadyEnabledMacStillOffersTheToggleInItsOnState() {
        #expect(OnboardingKeepAwakeOffer.make(
            isConnected: true,
            isSupported: true,
            isEnabled: true,
            isBusy: true
        ) == OnboardingKeepAwakeOffer(isEnabled: true, isBusy: true))
    }

    @Test func disconnectedMacNeverOffers() {
        #expect(OnboardingKeepAwakeOffer.make(
            isConnected: false,
            isSupported: true,
            isEnabled: true,
            isBusy: false
        ) == nil)
    }

    @Test func hostWithoutCaffeineControlNeverOffers() {
        #expect(OnboardingKeepAwakeOffer.make(
            isConnected: true,
            isSupported: false,
            isEnabled: true,
            isBusy: false
        ) == nil)
    }

    @Test func unknownStateHidesTheOfferInsteadOfShowingAnInertToggle() {
        #expect(OnboardingKeepAwakeOffer.make(
            isConnected: true,
            isSupported: true,
            isEnabled: nil,
            isBusy: false
        ) == nil)
    }
}
#endif
