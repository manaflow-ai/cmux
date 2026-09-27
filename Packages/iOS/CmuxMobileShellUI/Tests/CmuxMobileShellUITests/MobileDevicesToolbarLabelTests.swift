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

    @Test func noComputersHaveNoToolbarIndicator() {
        #expect(!MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: true,
            hasOutdatedListAuth: true,
            hasComputers: false
        ))
    }
}
#endif
