import CmuxNextDevices
@testable import CmuxNextMacScreen
import Testing

/// Screen Sharing ▸ on the new tab ⌄ menu of this Mac's own panes (Leo, 2026-11-18, c-b99282b1ed: "you should be
/// able to click the chevron next to teh + of new tab and just go there"). Those panes pass their daemon's id,
/// `local`, so the picker must read `local` as this Mac, and a remote machine's menu keeps the plain row.
@Suite struct MacScreenPickerScopeTests {
    @Test func thisMacsMenusGetThePicker() {
        #expect(MacScreenPickerMenu.isThisMac(nil))
        #expect(MacScreenPickerMenu.isThisMac("local"))
    }

    @Test func aRemoteMachinesMenuKeepsThePlainRow() {
        #expect(!MacScreenPickerMenu.isThisMac("mac-mini-7"))
    }

    /// A platform this app cannot decode (Windows) is nil on ``HubDevice``; the picker must not list it as a Mac.
    @Test func anUndecodedPlatformIsNotSentAsAbsent() {
        let device = HubDevice(id: "w", name: "PC", platform: nil, macScreenShared: true, online: true)
        let machine = ScreenPicker.Machine(device, onlineKnown: true, allowsRequests: true)
        #expect(machine.platform == "unknown")
    }
}
