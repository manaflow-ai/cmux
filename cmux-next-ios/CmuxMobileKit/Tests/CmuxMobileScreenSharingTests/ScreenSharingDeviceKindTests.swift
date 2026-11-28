#if os(iOS)
import CmuxDeviceHub
import Testing
import UIKit
@testable import CmuxMobileScreenSharing

/// Each Mac in Screen Sharing draws the glyph of the kind its hub record names (a MacBook, a
/// Mac mini), and this phone tells the hub it is an iPhone or an iPad.
@Suite @MainActor struct ScreenSharingDeviceKindTests {
    private func mac(kind: String?) -> HubDevice {
        HubDevice(id: "m", name: "Mac", platform: .macos, macScreenShared: true, kind: kind, online: true)
    }

    @Test func aMacDrawsTheGlyphOfItsKind() {
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: "macbook")) == "macbook.gen2")
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: "mac-mini")) == "macmini")
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: "linux-server")) == "server.rack")
    }

    @Test func aMacWithNoOrAnUnknownKindDrawsTheDesktopIcon() {
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: nil)) == "desktopcomputer")
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: "toaster")) == "desktopcomputer")
        #expect(ScreenSharingMacRow.glyph(of: mac(kind: "generic")) == "desktopcomputer")
    }

    @Test func thisDeviceSaysItsKindByIdiom() {
        #expect(ScreenSharingService.deviceKind(idiom: .phone) == "iphone")
        #expect(ScreenSharingService.deviceKind(idiom: .pad) == "ipad")
        // Both are names the generated table (cmux-device-kind) knows, so the Mac draws them.
        #expect(DeviceGlyphKind(name: ScreenSharingService.deviceKind(idiom: .phone)) != nil)
        #expect(DeviceGlyphKind(name: ScreenSharingService.deviceKind(idiom: .pad)) != nil)
    }
}
#endif
