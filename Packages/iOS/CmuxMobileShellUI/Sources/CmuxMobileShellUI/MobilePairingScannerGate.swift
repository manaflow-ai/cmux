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

    var allowsScanner: Bool {
        setupStatus != .notSelected
    }
}
#endif
