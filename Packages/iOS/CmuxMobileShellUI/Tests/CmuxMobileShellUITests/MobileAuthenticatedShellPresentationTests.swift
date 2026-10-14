#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileAuthenticatedShellPresentationTests {
    @Test func allHiddenUsesWorkspaceShellEvenWithStaleFalseHint() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: true
        ) == .workspace)
    }

    @Test func trulyNoMacsUsesDisconnectedAddDeviceShell() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .disconnected)
    }

    @Test(arguments: [MobileConnectionState.connected, .disconnected])
    func knownMacUsesWorkspaceShell(_ connectionState: MobileConnectionState) {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: connectionState,
            hasKnownPairedMac: true,
            hasHiddenComputers: false
        ) == .workspace)
    }

    @Test func cloudMachineAloneMountsTheWorkspaceShell() {
        // A Mac-less account with a Cloud machine must get the tab scaffold:
        // the add-device screen has no tabs, so the Cloud tab (and the
        // machine's own workspaces) would be unreachable.
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false,
            hasExternalHosts: true
        ) == .workspace)
    }

    @Test func connectedSessionUsesWorkspaceShellWithoutPersistedHints() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .connected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .workspace)
    }

}
#endif
