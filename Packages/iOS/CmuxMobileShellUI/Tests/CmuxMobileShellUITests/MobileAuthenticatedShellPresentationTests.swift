#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileWorkspace
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

    @Test func connectedSessionUsesWorkspaceShellWithoutPersistedHints() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .connected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .workspace)
    }

    @Test func finalComputerRemovalRetainsActiveWorkspaceChildHost() {
        let noComputers = MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: true
        )
        #expect(noComputers == .disconnectedNoKnownPairedMac)

        #expect(MobileAuthenticatedShellPresentation.retainingChildHost(
            .workspace,
            over: noComputers
        ) == .workspaceShell(isRestoringStoredMac: false))
    }

    @Test func reconnectRetainsActiveDisconnectedChildHost() {
        let connected = MobileRootAuthGate.shellSurface(
            connectionState: .connected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: false
        )
        #expect(connected == .workspaceShell(isRestoringStoredMac: false))

        #expect(MobileAuthenticatedShellPresentation.retainingChildHost(
            .disconnected,
            over: connected
        ) == .disconnectedNoKnownPairedMac)
    }

    @Test func noChildHostPreservesBaseShellAndRestoringPayload() {
        let restoring = MobileRootAuthGate.MobileRootShellSurface.workspaceShell(
            isRestoringStoredMac: true
        )

        #expect(MobileAuthenticatedShellPresentation.retainingChildHost(
            nil,
            over: restoring
        ) == restoring)
        #expect(MobileAuthenticatedShellPresentation.retainingChildHost(
            .workspace,
            over: restoring
        ) == restoring)
    }
}
#endif
