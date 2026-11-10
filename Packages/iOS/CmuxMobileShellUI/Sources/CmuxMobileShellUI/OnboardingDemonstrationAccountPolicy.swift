#if os(iOS)
import CmuxMobileShellModel

/// Onboarding adjustments for the server-flagged demonstration account (the
/// App Review account, `CMUXAuthUser.demonstrationContentEnabled`).
struct OnboardingDemonstrationAccountPolicy: Equatable {
    let isDemonstrationAccount: Bool

    func connectionPhase(_ livePhase: OnboardingConnectionPhase) -> OnboardingConnectionPhase {
        livePhase
    }

    var offersConnectionMethodChoice: Bool {
        true
    }

    func connectionMethod(_ storedMethod: MobileConnectionMethod) -> MobileConnectionMethod {
        storedMethod
    }
}
#endif
