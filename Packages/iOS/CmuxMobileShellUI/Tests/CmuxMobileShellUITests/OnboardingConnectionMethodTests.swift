#if os(iOS)
@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import Testing

@Suite struct OnboardingConnectionMethodTests {
    /// Onboarding offers every connection method, in the same order as the
    /// per-Computer picker in Settings, so the choice made during onboarding
    /// matches what users later find there. A method added to the model must
    /// be deliberately placed here instead of silently missing.
    @Test func onboardingOffersEveryConnectionMethod() {
        #expect(
            OnboardingConnectionMethodPicker.offeredMethods
                == [.automatic, .tailscale, .direct]
        )
        #expect(
            Set(OnboardingConnectionMethodPicker.offeredMethods)
                == Set(MobileConnectionMethod.allCases)
        )
    }

    /// Direct keeps the automatic discovery chrome: retries stay on the
    /// primary button with no pairing-scan secondary, and a ready connection
    /// still offers the completion action.
    @Test func directChromeMatchesAutomaticDiscoveryActions() {
        let idle = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .idle,
            connectionMethod: .direct
        )
        let fallback = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .fallback,
            connectionMethod: .direct
        )
        let ready = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .ready,
            connectionMethod: .direct
        )

        #expect(idle.primaryTitle != nil)
        #expect(idle.secondaryTitle == nil)
        #expect(fallback.primaryTitle != nil)
        #expect(fallback.secondaryTitle == nil)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
    }
}
#endif
