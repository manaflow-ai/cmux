import Testing
@testable import CmuxMobileShellUI

@Suite struct CmuxMobileShellUISmokeTests {
    @Test @MainActor func workspaceSettingsUsesConventionalSystemIcon() {
        #expect(MobileWorkspaceSettingsIcon.systemName == "gearshape")
    }

    @Test func knownMacRecoveryKeepsTheWorkspaceShellMounted() {
        #expect(MobileRootWorkspaceShellPolicy(
            isConnected: true,
            hasKnownPairedMac: true,
            isRestoringStoredMac: false
        ).keepsWorkspaceShellMounted)
        #expect(MobileRootWorkspaceShellPolicy(
            isConnected: false,
            hasKnownPairedMac: true,
            isRestoringStoredMac: true
        ).keepsWorkspaceShellMounted)
        #expect(MobileRootWorkspaceShellPolicy(
            isConnected: false,
            hasKnownPairedMac: true,
            isRestoringStoredMac: false
        ).keepsWorkspaceShellMounted)
        #expect(!MobileRootWorkspaceShellPolicy(
            isConnected: false,
            hasKnownPairedMac: false,
            isRestoringStoredMac: false
        ).keepsWorkspaceShellMounted)
    }
}
