#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Testing

@Suite struct MobilePairingScannerGateTests {
    /// App Review, iPad, 2026-11-07: on a fresh install (no paired Computer
    /// yet) the user picks Tailscale Only on onboarding's connect page and
    /// taps "Scan Pairing Code". The scanner must open.
    @Test func onboardingOpensScannerForTailscaleChoiceBeforeAnyComputer() {
        let gate = MobilePairingScannerGate(
            entry: .onboarding,
            setupStatus: .notSelected,
            onboardingMethod: .tailscale
        )
        #expect(gate.allowsScanner)
    }

    @Test func onboardingKeepsScannerClosedForAutomaticChoice() {
        let gate = MobilePairingScannerGate(
            entry: .onboarding,
            setupStatus: .notSelected,
            onboardingMethod: .automatic
        )
        #expect(!gate.allowsScanner)
    }

    /// Shell entry points still follow stored Computers only.
    @Test func shellFollowsStoredComputers() {
        let unselected = MobilePairingScannerGate(
            entry: .shell,
            setupStatus: .notSelected,
            onboardingMethod: .tailscale
        )
        #expect(!unselected.allowsScanner)
        for status in [MobileTailscaleSetupStatus.pairingRequired, .authorized, .loadingAuthorization] {
            let gate = MobilePairingScannerGate(entry: .shell, setupStatus: status, onboardingMethod: nil)
            #expect(gate.allowsScanner)
        }
    }
}
#endif
