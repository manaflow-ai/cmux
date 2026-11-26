#if os(iOS)
import CmuxMobileShellModel

/// Onboarding adjustments for the server-flagged demonstration account (the
/// App Review account, `CMUXAuthUser.demonstrationContentEnabled`).
struct OnboardingDemonstrationAccountPolicy: Equatable {
    let isDemonstrationAccount: Bool

    /// The Demo Mac is the demonstration account's Mac but never a live
    /// connection, so the connect step is ready as soon as the account is.
    func connectionPhase(_ livePhase: OnboardingConnectionPhase) -> OnboardingConnectionPhase {
        isDemonstrationAccount ? .ready : livePhase
    }

    /// App Review has no Tailscale network; the demonstration account never
    /// sees the Iroh / Tailscale Only choice.
    var offersConnectionMethodChoice: Bool {
        !isDemonstrationAccount
    }

    func connectionMethod(_ storedMethod: MobileConnectionMethod) -> MobileConnectionMethod {
        isDemonstrationAccount ? .automatic : storedMethod
    }
}
#endif
