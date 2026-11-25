import CmuxNextDevices
@testable import CmuxNextMacScreen
import Testing

/// A Linux desktop host is listed with its own platform label, never as a Mac.
@Suite struct MacScreenLinuxDeviceTests {
    @Test func eachPlatformHasItsOwnLabel() {
        #expect(MacScreenDevicesSettings.platformLabel(.linux) == "Linux")
        #expect(MacScreenDevicesSettings.platformLabel(.ios) == "iPhone")
        #expect(MacScreenDevicesSettings.platformLabel(.macos) == "Mac")
        #expect(MacScreenDevicesSettings.platformLabel(nil) == "Mac")
    }
}
