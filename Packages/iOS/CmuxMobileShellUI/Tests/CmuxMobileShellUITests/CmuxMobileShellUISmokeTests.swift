import Testing
@testable import CmuxMobileShellUI

/// CmuxMobileShellUI is UIKit-bound and iOS-only; its behavior is exercised by
/// the app build and the lower-layer packages' suites. This smoke test keeps the
/// test target valid for simulator-destination CI runs.
@Suite struct CmuxMobileShellUISmokeTests {
    @Test func moduleLinks() {
        #expect(Bool(true))
    }

    @Test func knownMacRecoveryKeepsTheWorkspaceShellMounted() {
        #expect(MobileRootWorkspaceShellPolicy.keepsWorkspaceShellMounted(
            isConnected: true,
            hasKnownPairedMac: true,
            isRestoringStoredMac: false
        ))
        #expect(MobileRootWorkspaceShellPolicy.keepsWorkspaceShellMounted(
            isConnected: false,
            hasKnownPairedMac: true,
            isRestoringStoredMac: true
        ))
        #expect(MobileRootWorkspaceShellPolicy.keepsWorkspaceShellMounted(
            isConnected: false,
            hasKnownPairedMac: true,
            isRestoringStoredMac: false
        ))
        #expect(!MobileRootWorkspaceShellPolicy.keepsWorkspaceShellMounted(
            isConnected: false,
            hasKnownPairedMac: false,
            isRestoringStoredMac: false
        ))
    }
}
