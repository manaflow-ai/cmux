#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDevicesToolbarLabelTests {
    @Test func gateWarningShowsTheToolbarIndicator() {
        #expect(MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: true,
            hasOutdatedListAuth: false
        ))
    }

    @Test func listAuthWarningShowsTheToolbarIndicator() {
        #expect(MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: false,
            hasOutdatedListAuth: true
        ))
    }

    @Test func compatibleComputersHaveNoToolbarIndicator() {
        #expect(!MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: false,
            hasOutdatedListAuth: false
        ))
    }

    /// SSH computers have no Mac version; the Mac floor must never read
    /// them as outdated (SSH-only mode showed "Mac update required").
    @Test func sshComputersNeverCountAsMacsForTheWarning() {
        let ssh = "cmux-ssh-8c4e2f6a-3b1d-4e5f-9a7b-1c2d3e4f5a6b"
        #expect(MobileDevicesToolbarLabel.macPairingIDs([ssh]).isEmpty)
        #expect(MobileDevicesToolbarLabel(computerPairingIDs: [ssh]).computerPairingIDs.isEmpty)
        #expect(MobileDevicesToolbarLabel.macPairingIDs([ssh, "mac-a"]) == ["mac-a"])
    }

    @Test func noComputersHaveNoToolbarIndicator() {
        #expect(!MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: true,
            hasOutdatedListAuth: true,
            hasComputers: false
        ))
    }
}
#endif
