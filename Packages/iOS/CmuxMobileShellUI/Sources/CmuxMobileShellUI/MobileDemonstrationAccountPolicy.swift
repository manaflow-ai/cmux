#if os(iOS)
import CmuxMobileShellModel

/// App-wide adjustments for the server-flagged demonstration account (the App
/// Review account, `CMUXAuthUser.demonstrationContentEnabled`). App Review has
/// no Mac and no Tailscale network: its Demo Mac is the only Computer, so no
/// pairing or connection-method path may be reachable for that account.
struct MobileDemonstrationAccountPolicy: Equatable {
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

    /// Whether Add Computer, the pairing scanner, and Tailscale setup appear.
    var allowsPairing: Bool {
        !isDemonstrationAccount
    }

    /// Whether a pairing presentation may open. Attach-ticket version approval
    /// is not a pairing entry point and is never refused.
    /// What's New announces connection methods and Mac requirements the
    /// demonstration account cannot use.
    func whatsNewPresentation(_ policy: MobileWhatsNewPresentationPolicy) -> MobileWhatsNewPresentationPolicy {
        policy
    }

    func allows(_ presentation: PairingPresentation) -> Bool {
        if case .versionApproval = presentation { return true }
        return allowsPairing
    }
}
#endif
