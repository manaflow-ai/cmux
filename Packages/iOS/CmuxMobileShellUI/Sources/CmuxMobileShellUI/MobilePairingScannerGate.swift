#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel

/// Whether a Tailscale pairing-scanner entry point may open the scanner.
struct MobilePairingScannerGate: Equatable {
    enum Entry: Equatable {
        /// Computers, Settings, and the disconnected shell.
        case shell
        /// Onboarding's connect page, which offers the scanner only after the
        /// user picks Tailscale Only on that page.
        case onboarding
    }

    let entry: Entry
    let setupStatus: MobileTailscaleSetupStatus
    let onboardingMethod: MobileConnectionMethod?

    /// Shell entry points follow stored Computers. Onboarding also follows the
    /// method picked on its connect page: a first-run install has no Computer
    /// to carry that choice yet, so gating onboarding on Computers alone left
    /// its "Scan Pairing Code" button inert.
    var allowsScanner: Bool {
        if setupStatus != .notSelected { return true }
        return entry == .onboarding && onboardingMethod == .tailscale
    }
}
#endif
