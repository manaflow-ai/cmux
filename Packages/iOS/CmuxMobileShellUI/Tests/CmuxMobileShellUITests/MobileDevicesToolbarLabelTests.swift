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

    @Test func unverifiedListAuthShowsTheToolbarIndicator() {
        #expect(MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: false,
            hasOutdatedListAuth: false,
            hasUnverifiedListAuth: true
        ))
    }

    @Test func compatibleComputersHaveNoToolbarIndicator() {
        #expect(!MobileDevicesToolbarLabel.warningVisible(
            hasGateWarning: false,
            hasOutdatedListAuth: false
        ))
    }
}
#endif
